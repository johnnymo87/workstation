import type { IncomingMessage, ServerResponse } from "node:http";
import http from "node:http";
import https from "node:https";
import path from "node:path";
import fs from "node:fs";
import { identify } from "./identity.js";
import { dispatch } from "./dispatch.js";
import { getRouteDisposition, OPERATOR_RUNBOOK } from "./routes.dispositions.js";
import { extractSids, type SidExtraction, SID_REGEX, extractSessionIdFromPath } from "./sid.js";
import { isExemptFromFirstByteTimeout } from "./timeouts.js";
import { resolveOwner } from "./resolve.js";
import { isPromotingRequest, isStatePinningRequest, maybePromote, PromotionGate, placeSession } from "./place.js";
import { StickyMap, isMutatingSessionRequest, sidsForStickiness } from "./sticky.js";
import { probeServeHealth } from "./health.js";
import { DEFAULT_ABANDONED_UPSTREAM_MAX_MS, DEFAULT_ABANDONED_UPSTREAM_MAX_CONCURRENT, type Config } from "./config.js";
import { RequestLogger, redactQuery } from "./log.js";
import { isAbsoluteHttpUrl, boundedFetch, stripTrailingSlashes, discardBody } from "./http.js";
import { isEventStreamResponse, pipeEventStream } from "./sse.js";
import { isHtmlResponse, isHtmlGuardExempt } from "./poison.js";
import { createDriftMonitor } from "./drift.js";
import { createWedgeProbe } from "./wedge.js";
import type { Metrics } from "./metrics.js";

export interface ProxyDeps {
  fetch?: typeof globalThis.fetch;
  now?: () => number;
}

export interface ProxyContext {
  config: Config;
  logger: RequestLogger;
  gate: PromotionGate;
  metrics: Metrics;
  sticky: StickyMap;
  deps?: ProxyDeps;
}

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade"
]);

// Cap on `?session_ids=` fan-out: each id becomes one concurrent pigeon /route
// lookup, so an unbounded list lets one client stampede the control plane.
const MAX_SESSION_IDS = 32;

export function buildForwardSearch(search: string, serveAuthHeader?: string): string {
  if (!serveAuthHeader || !search) {
    return search;
  }
  const params = new URLSearchParams(search);
  if (!params.has("auth_token")) {
    return search;
  }
  params.delete("auth_token");
  const s = params.toString();
  return s ? `?${s}` : "";
}

let poolCursor = 0;

// Upstream requests currently detached by abandonUpstream (process-wide).
let abandonedInFlight = 0;

export function resetPoolCursor(): void {
  poolCursor = 0;
}

export function poolOrder(poolUrls: string[], anchorUrl: string): string[] {
  if (poolUrls.length <= 1) return [...poolUrls];
  const start = poolCursor % poolUrls.length;
  poolCursor = (poolCursor + 1) % Number.MAX_SAFE_INTEGER;
  const rotated = [...poolUrls.slice(start), ...poolUrls.slice(0, start)];
  const primary = rotated[0];
  const rest = rotated.slice(1);
  const restWithoutAnchor = rest.filter((u) => u !== anchorUrl);
  if (rest.includes(anchorUrl)) {
    restWithoutAnchor.push(anchorUrl);
  }
  return [primary, ...restWithoutAnchor];
}

export type ProxyOutcome = "completed" | "upstream-unreachable" | "upstream-spurious-499";

/**
 * Status opencode's HTTP layer (effect HttpServerError.causeResponse) returns,
 * with an EMPTY body, for a cause that is interrupt-only and carries the
 * ClientAbort annotation — "client closed request". The door can never
 * legitimately receive one: it is reading the response, so its connection to
 * the serve is demonstrably open. A 499 here means the serve is REPLAYING an
 * earlier aborted request's memoized interruption (workstation-27r8).
 */
const UPSTREAM_CLIENT_CLOSED = 499;

const SPURIOUS_499_MESSAGE =
  "The upstream serve answered 499 (client closed request) although the front door's connection to it was open. " +
  "It is replaying an earlier aborted initialization for this directory and will keep doing so until that serve is restarted; " +
  "retrying the same request against it will not help.";

async function proxyRequest(
  target: string,
  method: string,
  url: URL,
  req: IncomingMessage,
  res: ServerResponse,
  ctx: ProxyContext,
  extraction: SidExtraction | null,
  options?: { failoverIfUnreachable?: boolean; failoverOnSpurious499?: boolean }
): Promise<ProxyOutcome> {
  return new Promise<ProxyOutcome>((resolve) => {
    const targetParsed = new URL(target);
    const clientModule = targetParsed.protocol === "https:" ? https : http;

    // Filter hop-by-hop headers
    const upstreamHeaders: Record<string, string | string[]> = {};
    for (const [key, val] of Object.entries(req.headers)) {
      if (val !== undefined && !HOP_BY_HOP_HEADERS.has(key.toLowerCase())) {
        upstreamHeaders[key] = val;
      }
    }
    // Set Host header
    upstreamHeaders["host"] = targetParsed.host;

    if (ctx.config.serveAuthHeader) {
      for (const k of Object.keys(upstreamHeaders)) {
        if (k.toLowerCase() === "authorization") {
          delete upstreamHeaders[k];
        }
      }
      upstreamHeaders["Authorization"] = ctx.config.serveAuthHeader;
    }

    const search = buildForwardSearch(url.search, ctx.config.serveAuthHeader);
    const path = targetParsed.pathname.replace(/\/+$/, "") + url.pathname + search;

    const upstreamReq = clientModule.request({
      method: method,
      hostname: targetParsed.hostname,
      port: targetParsed.port || (targetParsed.protocol === "https:" ? 443 : 80),
      path,
      headers: upstreamHeaders,
    });

    let headersSent = false;
    let resolved = false;
    let cheapTimeoutId: ReturnType<typeof setTimeout> | null = null;
    let wedgeProbe: ReturnType<typeof createWedgeProbe> | null = null;
    // Set once this attempt has handed the client response to the NEXT pool member
    // (spurious-499 failover). Anything this upstream does afterwards is not ours.
    let handedOff = false;

    // workstation-27r8: whether the upstream has sent response headers yet, and
    // whether we have detached from it. See abandonUpstream.
    let upstreamResponded = false;
    let abandoned = false;
    const detachable = method === "GET" || method === "HEAD";

    /**
     * Stop caring about the upstream's answer WITHOUT closing the connection.
     *
     * opencode builds per-directory state lazily, inside the request fiber of
     * the first caller that needs it, and memoizes the result for the life of
     * the process (InstanceState -> ScopedCache, infinite TTL). If that socket
     * closes mid-init the fiber is interrupted with a ClientAbort annotation,
     * the interrupted Exit is what gets memoized, and every later request for the
     * directory is answered 499 until the serve restarts. That is what a
     * destroy() here did on 2026-10-02: one 5s timeout on the first
     * GET /config/providers for ~/Code wedged it on the anchor for 2.5h+.
     *
     * So for side-effect-free methods, before the upstream has answered, let the
     * request run to completion and drain it. The client still gets its 503 on
     * time — the 5s budget and its fast-fail semantics are unchanged — and the
     * serve's init completes and caches a success, so the client's retry works.
     * Bounded by abandonedUpstreamMaxMs; past that we destroy as before.
     *
     * Not for other methods: a mutation the client has given up on is better
     * cancelled than completed unobserved, and that is the pre-existing contract.
     */
    const abandonUpstream = (why: string) => {
      if (abandoned) return;
      abandoned = true;
      // Bounded concurrency. Detaching turns cancellation into completion, so
      // under a burst against an already-saturated serve it no longer sheds
      // work. Poisoning only needs the FIRST caller per directory to survive,
      // and a burst's tail is mostly waiters on that same init, so a modest cap
      // keeps the protection while restoring eon4's load-shedding past it.
      const maxConcurrent = ctx.config.abandonedUpstreamMaxConcurrent ?? DEFAULT_ABANDONED_UPSTREAM_MAX_CONCURRENT;
      if (abandonedInFlight >= maxConcurrent) {
        ctx.metrics.upstreamAbandonedKilled++;
        console.warn(
          `[FRONTDOOR WARN] ${abandonedInFlight} upstreams already detached (cap ${maxConcurrent}); destroying ${method} ${url.pathname} -> ${target} (${why}), which may poison that serve's per-directory state (499s)`
        );
        upstreamReq.destroy();
        return;
      }
      abandonedInFlight++;
      ctx.metrics.upstreamAbandoned++;
      const maxMs = ctx.config.abandonedUpstreamMaxMs ?? DEFAULT_ABANDONED_UPSTREAM_MAX_MS;
      const ceiling = setTimeout(() => {
        if (upstreamResponded) return;
        ctx.metrics.upstreamAbandonedKilled++;
        console.warn(
          `[FRONTDOOR WARN] abandoned upstream ${method} ${url.pathname} -> ${target} still unanswered after ${maxMs}ms (${why}); destroying it, which may poison that serve's per-directory state (499s)`
        );
        upstreamReq.destroy();
      }, maxMs);
      // Never hold the process open for a request nobody is waiting on.
      ceiling.unref();
      upstreamReq.once("close", () => {
        clearTimeout(ceiling);
        abandonedInFlight--;
      });
    };

    const onReqError = (err: any) => {
      upstreamReq.destroy();
      if (!headersSent && !res.headersSent) {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "bad_request" }));
      }
      safeResolve();
    };

    const onResError = (err: any) => {
      upstreamReq.destroy();
      safeResolve();
    };

    const onClose = () => {
      if (!res.writableEnded) {
        if (detachable && !upstreamResponded) {
          // The client hung up before the upstream answered (e.g. a TUI quit
          // during a slow startup). Same poisoning hazard as the first-byte
          // timeout; see abandonUpstream.
          abandonUpstream("client closed");
        } else {
          upstreamReq.destroy();
        }
      }
      safeResolve();
    };

    const safeResolve = (outcome: ProxyOutcome = "completed") => {
      if (resolved) return;
      resolved = true;
      if (cheapTimeoutId) {
        clearTimeout(cheapTimeoutId);
        cheapTimeoutId = null;
      }
      if (wedgeProbe) {
        wedgeProbe.stop();
        wedgeProbe = null;
      }
      req.off("error", onReqError);
      res.off("error", onResError);
      res.off("close", onClose);
      req.unpipe(upstreamReq);
      resolve(outcome);
    };

    req.on("error", onReqError);
    res.on("error", onResError);

    // Handle connect / first byte timeouts (true wall-clock time-to-response-headers)
    const isExempt = isExemptFromFirstByteTimeout(method, url.pathname, extraction);
    if (!isExempt) {
      cheapTimeoutId = setTimeout(() => {
        if (!headersSent && !res.headersSent) {
          headersSent = true;
          res.writeHead(503, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "service_unavailable", message: "Upstream did not send response headers in time" }));
          if (detachable) {
            abandonUpstream("first-byte timeout");
          } else {
            upstreamReq.destroy();
          }
          safeResolve();
        }
      }, ctx.config.cheapFirstByteMs);
    } else {
      wedgeProbe = createWedgeProbe({
        target,
        config: ctx.config,
        deps: ctx.deps,
        onWedged: () => {
          if (!headersSent && !res.headersSent) {
            headersSent = true;
            res.writeHead(503, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "service_unavailable", message: "Target serve failed health probe (wedged)" }));
            upstreamReq.destroy();
            safeResolve();
          }
        }
      });
      wedgeProbe.start();
    }

    upstreamReq.on("response", (upstreamRes) => {
      upstreamResponded = true;
      if (abandoned) {
        // Nobody is waiting for this answer, and on the client-close path `res`
        // is already destroyed: piping into it would stall the upstream body
        // forever once it outgrows the socket buffer. A stream never ends on its
        // own, so close it; headers mean the handler (and any init it ran)
        // already completed, so that cannot poison anything. Otherwise drain.
        if (isEventStreamResponse(upstreamRes.headers)) {
          upstreamReq.destroy();
        } else {
          upstreamRes.resume();
        }
        return;
      }
      if (cheapTimeoutId) {
        clearTimeout(cheapTimeoutId);
        cheapTimeoutId = null;
      }
      if (wedgeProbe) {
        wedgeProbe.stop();
        wedgeProbe = null;
      }
      if (res.headersSent || headersSent || handedOff) {
        upstreamRes.resume(); // drain to release the socket back to the pool
        return;
      }

      if (upstreamRes.statusCode === UPSTREAM_CLIENT_CLOSED) {
        ctx.metrics.upstreamSpurious499++;
        upstreamRes.resume();
        const failover = options?.failoverOnSpurious499 === true;
        const q = redactQuery(url.search);
        // The operator log names the serve and the directory: that pair is the
        // poisoned cache entry, and restarting that serve is the remedy.
        console.warn(
          `[FRONTDOOR WARN] spurious 499: ${method} ${url.pathname}${q ? "?" + q : ""} -> ${target} answered 499 on an open connection (memoized aborted init; restart that serve); ${failover ? "failing over to next pool member" : "returned 503"}`
        );
        if (failover) {
          handedOff = true;
          safeResolve("upstream-spurious-499");
          return;
        }
        headersSent = true;
        // Target serve is omitted from client-visible response for network opacity.
        res.writeHead(503, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "service_unavailable", message: SPURIOUS_499_MESSAGE }));
        safeResolve();
        return;
      }

      headersSent = true;

      if (isHtmlResponse(upstreamRes.headers["content-type"]) && !isHtmlGuardExempt(method, url.pathname)) {
        ctx.metrics.htmlPoisonBlocked++;
        console.warn(
          `[FRONTDOOR WARN] html-poison blocked: ${method} ${url.pathname} -> ${target} returned ${upstreamRes.statusCode} text/html (stale-serve SPA fallback); returned 502`
        );
        // Target serve is omitted from client-visible response for network opacity.
        res.writeHead(502, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            error: "bad_gateway",
            message:
              "Upstream returned an HTML page for an API route. The target serve is probably running an older binary that lacks this route; restart the serve pool.",
          })
        );
        upstreamRes.resume();
        safeResolve();
        return;
      }

      const clientHeaders: Record<string, string | string[]> = {};
      for (const [key, val] of Object.entries(upstreamRes.headers)) {
        if (val !== undefined && !HOP_BY_HOP_HEADERS.has(key.toLowerCase())) {
          clientHeaders[key] = val;
        }
      }

      res.writeHead(upstreamRes.statusCode || 200, clientHeaders);

      if (isEventStreamResponse(upstreamRes.headers)) {
        let monitor: ReturnType<typeof createDriftMonitor> | null = null;
        if (extraction && (extraction.kind === "single" || extraction.kind === "multi")) {
          monitor = createDriftMonitor({
            extraction,
            currentOwner: target,
            config: ctx.config,
            isMidTurn: () => sidsForStickiness(extraction).some((s) => ctx.sticky.has(s, ctx.deps?.now?.() ?? Date.now())),
            deps: ctx.deps,
            onDrop: () => {
              upstreamRes.destroy();
              res.end();
            }
          });
          monitor.start();
        }

        pipeEventStream(upstreamRes, res, {
          onDone: () => {
            if (monitor) {
              monitor.stop();
            }
            safeResolve();
          }
        });
      } else {
        upstreamRes.pipe(res);

        upstreamRes.on("error", (err) => {
          res.destroy();
          safeResolve();
        });

        upstreamRes.on("end", () => {
          safeResolve();
        });
      }
    });

    upstreamReq.on("error", (err) => {
      // After a hand-off, `res` belongs to the next pool member's attempt.
      if (handedOff) return;
      if (!headersSent && !res.headersSent) {
        if (options?.failoverIfUnreachable) {
          req.unpipe(upstreamReq);
          safeResolve("upstream-unreachable");
          return;
        }
        res.writeHead(502, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "bad_gateway", message: err.message }));
      } else if (!res.writableEnded) {
        // Avoid an abrupt RST that races the already-flushed response (e.g. the
        // 503 first-byte-timeout path calls upstreamReq.destroy(), which can
        // surface here after res.end()). Only tear down if still writable.
        res.destroy();
      }
      safeResolve("completed");
    });

    // Note: on pool failover, re-piping an already-ended req works because Node schedules
    // dest.end() on nextTick when endEmitted is set. Safe only because guard tests
    // confine poolSafe to GET/HEAD (no body to lose).
    req.pipe(upstreamReq);

    res.on("close", onClose);
  });
}

function forwardableResponseHeaders(headers: Headers): Record<string, string> {
  const out: Record<string, string> = {};
  headers.forEach((value, key) => {
    const k = key.toLowerCase();
    if (!HOP_BY_HOP_HEADERS.has(k) && k !== "content-length" && k !== "content-encoding") {
      out[key] = value;
    }
  });
  return out;
}

async function readIncomingBody(req: IncomingMessage, limitBytes = 1048576): Promise<string> {
  // No wall-clock timer here by design — the door binds 127.0.0.1 (trusted local clients)
  // and a trickling client is bounded by Node's default `server.requestTimeout`;
  // the W9 slow-upload protection applies to the streaming `proxyRequest` path,
  // not this buffered mint path.
  return new Promise<string>((resolve, reject) => {
    const chunks: Buffer[] = [];
    let totalBytes = 0;
    let overLimit = false;

    req.on("data", (chunk: Buffer) => {
      totalBytes += chunk.length;
      if (totalBytes > limitBytes) {
        if (!overLimit) {
          overLimit = true;
          reject(new Error("payload_too_large"));
        }
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (!overLimit) {
        resolve(Buffer.concat(chunks).toString("utf8"));
      }
    });
    req.on("error", (err) => {
      reject(err);
    });
  });
}

/**
 * Minter re-scan verified conclusion:
 * Only POST /session (create) and POST /session/{id}/fork mint new sids.
 * GET /session/{id}/children is a read/list; update/share/unshare/part-update
 * all return Session.Info for an existing path sid (not minters).
 * No other minting routes to handle.
 */
async function placeAfterCreate(
  target: string,
  req: IncomingMessage,
  res: ServerResponse,
  ctx: ProxyContext,
  url: URL,
): Promise<{ sid: string | null; degraded: boolean }> {
  // Both minters (create, fork) are POST; boundedFetch below hardcodes "POST".
  let createdSid: string | null = null;
  let degradedState = false;

  let clientBody: string;
  try {
    clientBody = await readIncomingBody(req);
  } catch (err: any) {
    if (err?.message === "payload_too_large") {
      res.writeHead(413, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "payload_too_large", message: "Request body exceeds maximum size" }));
    } else {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "bad_request", message: "Failed to read request body" }));
    }
    return { sid: null, degraded: false };
  }

  const forwardHeaders: Record<string, string> = {};
  for (const [key, val] of Object.entries(req.headers)) {
    const k = key.toLowerCase();
    if (val !== undefined && !HOP_BY_HOP_HEADERS.has(k) && k !== "host") {
      forwardHeaders[key] = Array.isArray(val) ? val.join(", ") : val;
    }
  }

  if (ctx.config.serveAuthHeader) {
    for (const k of Object.keys(forwardHeaders)) {
      if (k.toLowerCase() === "authorization") {
        delete forwardHeaders[k];
      }
    }
    forwardHeaders["Authorization"] = ctx.config.serveAuthHeader;
  }

  const search = buildForwardSearch(url.search, ctx.config.serveAuthHeader);
  const targetBase = stripTrailingSlashes(target);
  const targetUrl = `${targetBase}${url.pathname}${search}`;

  const result = await boundedFetch(targetUrl, {
    method: "POST",
    timeoutMs: ctx.config.mintTimeoutMs,
    headers: forwardHeaders,
    body: clientBody,
    fetchImpl: ctx.deps?.fetch,
  });

  if (!result.ok) {
    if (result.timedOut) {
      res.writeHead(504, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "gateway_timeout", message: "Anchor did not respond in time" }));
    } else {
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "bad_gateway", message: "Failed to connect to anchor" }));
    }
    return { sid: null, degraded: false };
  }

  const response = result.response!;

  if (isHtmlResponse(response.headers.get("content-type") ?? undefined)) {
    // Note: placeAfterCreate handles POST /session and POST /session/{id}/fork, neither of which is or can be exempt.
    ctx.metrics.htmlPoisonBlocked++;
    console.warn(
      `[FRONTDOOR WARN] html-poison blocked: ${req.method ?? "POST"} ${url.pathname} -> ${target} returned ${response.status} text/html (stale-serve SPA fallback); returned 502`
    );
    // Target serve is omitted from client-visible response for network opacity.
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_gateway",
        message:
          "Upstream returned an HTML page for an API route. The target serve is probably running an older binary that lacks this route; restart the serve pool.",
      })
    );
    discardBody(response);
    return { sid: null, degraded: false };
  }

  if (response.status < 200 || response.status >= 300) {
    const anchorBody = await response.text();
    const responseHeaders = forwardableResponseHeaders(response.headers);
    res.writeHead(response.status, responseHeaders);
    res.end(anchorBody);
    return { sid: null, degraded: false };
  }

  const anchorBody = await response.text();
  let parsedSid: string | undefined;
  let parsedParentId: string | undefined;
  try {
    const parsed = JSON.parse(anchorBody);
    if (parsed && typeof parsed === "object" && typeof parsed.id === "string") {
      parsedSid = parsed.id;
      if (typeof parsed.parentID === "string" && parsed.parentID.length > 0) {
        parsedParentId = parsed.parentID;
      }
    }
  } catch (err) {
    // invalid JSON
  }

  if (!parsedSid || !SID_REGEX.test(parsedSid)) {
    console.warn("[FRONTDOOR WARN] Create response JSON missing session id");
    degradedState = true;
    const responseHeaders = forwardableResponseHeaders(response.headers);
    res.writeHead(response.status, responseHeaders);
    res.end(anchorBody);
    return { sid: null, degraded: degradedState };
  }

  createdSid = parsedSid;

  // A CHILD must never be placed with pigeon: pigeon's placement is HRW and
  // parent-unaware, so an assignment for a child pins it to an arbitrary serve and
  // permanently shadows the parent walk (pigeon /route would then 200). Normally
  // children are minted in-process by the Task tool and never reach the door, but
  // `POST /session` accepts a `parentID` in the body (verified live against the
  // deployed rev), so a client CAN create one through the door. We already parsed
  // the mint response — trust that field rather than an assumption about callers.
  // Skip placement; the child resolves to its root's owner via the parent walk.
  if (parsedParentId) {
    console.warn(
      `[FRONTDOOR WARN] Created session ${parsedSid} has parentID ${parsedParentId}; skipping pigeon placement (children follow their root's owner).`,
    );
    const responseHeaders = forwardableResponseHeaders(response.headers);
    res.writeHead(response.status, responseHeaders);
    res.end(anchorBody);
    return { sid: createdSid, degraded: degradedState };
  }

  const placeResult = await placeSession(parsedSid, ctx.config, ctx.deps);

  if (placeResult.ok) {
    const now = ctx.deps?.now?.() ?? Date.now();
    if (placeResult.apiBase && isAbsoluteHttpUrl(placeResult.apiBase)) {
      // routingSid MUST be passed explicitly: StickyMap.record defaults it to null
      // for a NEW entry, and a null routingSid gates off lease renewal entirely
      // (see the renewal branch below). A session minted by create or fork is
      // always a ROOT — a fork gets no parentID (verified live against the
      // deployed rev) — so it renews its own lease.
      ctx.sticky.record(parsedSid, placeResult.apiBase, now, now, parsedSid);
    }
  } else {
    degradedState = true;
    console.warn(`[FRONTDOOR WARN] placeSession failed for sid: ${parsedSid}, status: ${placeResult.status}`);
  }

  const responseHeaders = forwardableResponseHeaders(response.headers);
  res.writeHead(response.status, responseHeaders);
  res.end(anchorBody);
  return { sid: createdSid, degraded: degradedState };
}

async function handleCreate(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: ProxyContext,
  url: URL,
): Promise<{ sid: string | null; degraded: boolean }> {
  return placeAfterCreate(ctx.config.anchorUrl, req, res, ctx, url);
}

async function handleFork(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: ProxyContext,
  url: URL,
): Promise<{ sid: string | null; degraded: boolean }> {
  const parent = extractSessionIdFromPath(url.pathname);
  if (!parent || !SID_REGEX.test(parent)) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "bad_request", message: "Malformed session ID" }));
    return { sid: null, degraded: false };
  }

  const resolved = await resolveOwner(parent, ctx.config, ctx.deps);
  const r = await placeAfterCreate(resolved.url, req, res, ctx, url);
  return { sid: r.sid, degraded: r.degraded || resolved.degraded };
}

async function handleMoveSession(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: ProxyContext,
  url: URL,
): Promise<{ sid: string | null; target: string; reason?: string }> {
  // 1. extractSessionIdFromPath(url.pathname); !sid || !SID_REGEX.test(sid) -> 400
  const sid = extractSessionIdFromPath(url.pathname);
  if (!sid || !SID_REGEX.test(sid)) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "bad_request", message: "Malformed session ID" }));
    return { sid: null, target: "" };
  }

  // 2. readIncomingBody(req, 16384) -> on payload_too_large 413, other read error 400.
  let clientBody: string;
  try {
    clientBody = await readIncomingBody(req, 16384);
  } catch (err: any) {
    if (err?.message === "payload_too_large") {
      res.writeHead(413, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "payload_too_large", message: "Request body exceeds maximum size" }));
    } else {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "bad_request", message: "Failed to read request body" }));
    }
    return { sid, target: "" };
  }

  // 3. JSON.parse -> 400 on invalid JSON.
  let parsedBody: any;
  try {
    parsedBody = JSON.parse(clientBody);
  } catch {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "bad_request", message: "Invalid JSON body" }));
    return { sid, target: "" };
  }

  // 4. Shape validation:
  if (!parsedBody || typeof parsedBody !== "object" || Array.isArray(parsedBody)) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "bad_request", message: "Request body must be an object" }));
    return { sid, target: "" };
  }

  if ("moveChanges" in parsedBody) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_request",
        message:
          "moveChanges is not supported through the front door: on a live source it runs 'git change discard … untracked: remove' and can destroy uncommitted work",
      })
    );
    return { sid, target: "" };
  }

  if ("sessionID" in parsedBody) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_request",
        message:
          "sessionID must not be specified in request body; the path is the only authority for which session moves",
      })
    );
    return { sid, target: "" };
  }

  const bodyKeys = Object.keys(parsedBody);
  const extraBodyKeys = bodyKeys.filter((k) => k !== "destination");
  if (extraBodyKeys.length > 0 || !bodyKeys.includes("destination")) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_request",
        message:
          extraBodyKeys.length > 0
            ? `Unexpected key in request body: ${extraBodyKeys.join(", ")}`
            : "Missing destination in request body",
      })
    );
    return { sid, target: "" };
  }

  const dest = parsedBody.destination;
  if (!dest || typeof dest !== "object" || Array.isArray(dest)) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "bad_request", message: "destination must be an object" }));
    return { sid, target: "" };
  }

  const destKeys = Object.keys(dest);
  const extraDestKeys = destKeys.filter((k) => k !== "directory");
  if (extraDestKeys.length > 0 || !destKeys.includes("directory")) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_request",
        message:
          extraDestKeys.length > 0
            ? `Unexpected key in destination: ${extraDestKeys.join(", ")}`
            : "Missing directory in destination",
      })
    );
    return { sid, target: "" };
  }

  const dir = dest.directory;
  if (typeof dir !== "string") {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "bad_request", message: "destination.directory must be a string" }));
    return { sid, target: "" };
  }

  if (dir.length === 0) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "bad_request", message: "destination.directory must be non-empty" }));
    return { sid, target: "" };
  }

  if (!dir.startsWith("/")) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "bad_request", message: "destination.directory must start with /" }));
    return { sid, target: "" };
  }

  if (path.resolve(dir) !== dir) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_request",
        message:
          "destination.directory must be an absolute normalized path without '.', '..', '//', or trailing slash",
      })
    );
    return { sid, target: "" };
  }

  // 5. Verify destination directory exists and is a directory.
  // Must use async fs.promises.stat: the door is a single-threaded proxy for all pool
  // traffic and must never execute a blocking syscall.
  //
  // Ordering and rationale:
  // This check is performed BEFORE resolveOwner and before forwarding upstream.
  // A 400 returned here guarantees "the move definitely did not happen" (no upstream
  // state mutation, no Moved event published). Checking as late in validation as possible
  // also shrinks the window in which a concurrent sweeper could delete the directory
  // between creation and the move.
  //
  // Why stat instead of lstat:
  // fs.promises.stat follows symlinks. A worktree or project path reachable through a
  // symlinked directory is legitimate, so symlink targets must be resolved and checked
  // for directory status. Do NOT change this to lstat.
  let stats: fs.Stats;
  try {
    stats = await fs.promises.stat(dir);
  } catch {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_request",
        message: "destination.directory does not exist or is not readable",
      })
    );
    return { sid, target: "" };
  }

  if (!stats.isDirectory()) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_request",
        message: "destination.directory is not a directory",
      })
    );
    return { sid, target: "" };
  }

  // 6. resolveOwner(sid, ctx.config, ctx.deps) (read-only; it only GETs pigeon /route and may walk parentage).
  const resolved = await resolveOwner(sid, ctx.config, ctx.deps);
  // Rationale: an active owner must receive it so the Moved event reaches an
  // attached TUI's serve; for every other reason (prospective / not-routed / pigeon down)
  // the anchor is correct, and we deliberately do NOT use resolved.url for prospective,
  // because that is an HRW guess and routing a mutation there is what 5obe punished.
  const target = resolved.reason === "active" ? resolved.url : ctx.config.anchorUrl;

  // 7. boundedFetch(`${stripTrailingSlashes(target)}/experimental/control-plane/move-session`, {...})
  const forwardHeaders: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (ctx.config.serveAuthHeader) {
    forwardHeaders["Authorization"] = ctx.config.serveAuthHeader;
  }
  // Do not forward arbitrary client headers (unlike placeAfterCreate): this is a door-owned
  // request with a door-constructed body, so the client's headers have no standing.
  const targetBase = stripTrailingSlashes(target);
  const forwardUrl = `${targetBase}/experimental/control-plane/move-session`;
  const forwardBody = JSON.stringify({
    sessionID: sid,
    destination: { directory: dir },
  });

  const result = await boundedFetch(forwardUrl, {
    method: "POST",
    timeoutMs: ctx.config.mintTimeoutMs,
    headers: forwardHeaders,
    body: forwardBody,
    fetchImpl: ctx.deps?.fetch,
  });

  // 8. Response mapping (be exhaustive; a test per row):
  if (!result.ok) {
    if (result.timedOut) {
      res.writeHead(504, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          error: "gateway_timeout",
          message: "Move outcome unknown; re-read the session before any cleanup.",
        })
      );
    } else {
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "bad_gateway", message: "Failed to connect to target serve" }));
    }
    return { sid, target, reason: resolved.reason };
  }

  const response = result.response!;

  if (isHtmlResponse(response.headers.get("content-type") ?? undefined)) {
    ctx.metrics.htmlPoisonBlocked++;
    console.warn(
      `[FRONTDOOR WARN] html-poison blocked: POST ${url.pathname} -> ${target} returned ${response.status} text/html (stale-serve SPA fallback); returned 502`
    );
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_gateway",
        message:
          "Upstream returned an HTML page for an API route. The target serve is probably running an older binary that lacks this route; restart the serve pool.",
      })
    );
    discardBody(response);
    return { sid, target, reason: resolved.reason };
  }

  if (response.status === 204) {
    res.writeHead(204);
    res.end();
    discardBody(response);
    return { sid, target, reason: resolved.reason };
  }

  if (response.status >= 200 && response.status < 300) {
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_gateway",
        message: "Unexpected upstream status for move-session",
      })
    );
    discardBody(response);
    return { sid, target, reason: resolved.reason };
  }

  // Defensive branch: boundedFetch does not pass a `redirect` option, and undici
  // follows redirects by default, so a 3xx response is unreachable in production.
  // Kept defensively to guarantee a redirect cannot be blindly relayed or swallowed.
  if (response.status >= 300 && response.status < 400) {
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        error: "bad_gateway",
        message: "Unexpected redirect from upstream for move-session",
      })
    );
    discardBody(response);
    return { sid, target, reason: resolved.reason };
  }

  if (response.status >= 400 && response.status < 600) {
    const upstreamBody = await response.text();
    const responseHeaders = forwardableResponseHeaders(response.headers);
    res.writeHead(response.status, responseHeaders);
    res.end(upstreamBody);
    return { sid, target, reason: resolved.reason };
  }

  // Any other status: 502
  res.writeHead(502, { "Content-Type": "application/json" });
  res.end(
    JSON.stringify({
      error: "bad_gateway",
      message: "Unexpected upstream status for move-session",
    })
  );
  discardBody(response);
  return { sid, target, reason: resolved.reason };
}

export async function handleRequest(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: ProxyContext
): Promise<void> {
  const startTime = Date.now();
  let logged = false;

  let sid: string | null = null;
  let target = "";
  let prospective = false;
  let degraded = false;
  // sq1v observability: recorded so a child's routing is an OBSERVATION in the log
  // rather than something that has to be inferred from pigeon state after the fact.
  let viaParent: boolean | undefined;
  let routingSid: string | null | undefined;
  let reason: string | undefined;

  const method = req.method || "GET";
  const url = new URL(req.url || "", "http://internal");

  let decision = dispatch(method, url.pathname);

  function logResponse() {
    if (logged) return;
    logged = true;
    if (degraded) {
      ctx.metrics.degradedRequests++;
    }
    const durationMs = Date.now() - startTime;
    ctx.logger.log({
      class: decision.class,
      sid,
      target,
      prospective,
      degraded,
      viaParent,
      routingSid,
      reason,
      status: res.statusCode || 200,
      durationMs,
      method,
      path: url.pathname,
      // Without the query this log cannot tell /config from /config?directory=<x>,
      // which is exactly the distinction that misled workstation-eon4. Redacted.
      query: redactQuery(url.search),
      // decision.action was declared in RequestLogEntry but never populated here, so
      // the routing decision (forward-anchor, sticky, create...) had to be inferred
      // from class+target after the fact.
      action: decision.action
    });
  }

  res.on("finish", logResponse);
  res.on("close", logResponse);

  try {
    // 2. Identify the request (no-op seam)
    identify(req);

    // 4. Branch on decision.action
    if (decision.action === "not-found-404") {
      // web-ui is defensively kept loud even though the table currently maps no
      // route to it (see NEW-D scope statement in routes.classification.ts).
      if (decision.class === "web-ui") {
        console.warn(`[FRONTDOOR WARN] Web UI endpoint is unsupported through the front door: ${method} ${url.pathname}`);
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          error: "web_ui_not_served",
          message: `The web UI is not served through the front door. Opening it is an interactive operator action, not a fallback for this request: see ${OPERATOR_RUNBOOK} §4.`
        }));
      } else {
        console.warn(`[FRONTDOOR WARN] Unrecognized pathname: ${method} ${url.pathname}`);
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "not_found" }));
      }
      return;
    }

    if (decision.action === "deny-global-mutation") {
      // The denial body is the ONLY thing the caller sees, so it must not
      // recommend a workaround that is wrong for this specific route. The
      // generic hint is safe for genuinely
      // process-local rows, but for anything backed by pool-wide state it
      // instructs the caller to manufacture exactly the silent inconsistency
      // the denial exists to prevent (docs/plans/2026-07-26-mlve11-d4-mechanisms.md,
      // R2). Rows that need better wording carry `userMessage`/`remedy` in
      // ROUTE_DISPOSITIONS; everything else keeps the previous text.
      const disposition = getRouteDisposition(method, url.pathname, decision.class);
      const remedy = disposition?.remedy
        ?? `This operation mutates state that belongs to a single serve process, so the front door cannot perform it on your behalf. It is not a routing failure and there is no port to retry against: if you genuinely need it, it is an operator procedure — see ${OPERATOR_RUNBOOK}.`;

      if (decision.allowedMethods.length > 0) {
        const allowedJoined = decision.allowedMethods.join(", ");
        const why = disposition?.userMessage
          ?? `${method} ${url.pathname} mutates per-process state and is not proxied through the front door.`;
        console.warn(`[FRONTDOOR WARN] Global mutation not proxied through the front door (405): ${method} ${url.pathname}`);
        res.writeHead(405, {
          "Content-Type": "application/json",
          "Allow": allowedJoined
        });
        res.end(JSON.stringify({
          error: "method_not_allowed_through_frontdoor",
          // `message` intentionally repeats `remedy`: many clients surface only
          // this field, and the remedy is the half that keeps them out of trouble.
          message: `${method} ${url.pathname} is not proxied through the front door. ${why} Allowed through the door: ${allowedJoined}. ${remedy}`,
          reason: why,
          remedy,
          allowed: decision.allowedMethods
        }));
      } else {
        const why = disposition?.userMessage
          ?? `${method} ${url.pathname} mutates per-process/single-process state.`;
        console.warn(`[FRONTDOOR WARN] Global mutation not proxied through the front door (403): ${method} ${url.pathname}`);
        res.writeHead(403, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          error: "forbidden_through_frontdoor",
          message: `${method} ${url.pathname} is not proxied through the front door. ${why} ${remedy}`,
          reason: why,
          remedy
        }));
      }
      return;
    }

    if (decision.action === "gone-410") {
      console.warn(`[FRONTDOOR WARN] /global/event firehose is gone from the front-door contract (410): ${method} ${url.pathname}`);
      res.writeHead(410, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "gone" }));
      return;
    }

    // PTY is out of scope for v1: Phase 0.5 exhaustively grepped opencode-patched and
    // found NO deployed client constructs /pty/*. So there is no WebSocket proxying /
    // raw tunnel in v1.
    // Future path if a client ever adds PTY: revisit with a Node raw duplex tunnel
    // (Node 22 is present and its socket-hijack path is verified). NOTE bun 1.3.3's
    // socket hijack silently fails — hence Node was retained as the runtime.
    // /pty/{ptyID}/connect is a WS upgrade keyed by ptyID (not a session id), with
    // state in-process on the creating serve, so it would also need a ptyID->serve pin.
    if (decision.action === "pty-501") {
      console.warn(`[FRONTDOOR WARN] PTY request denied (out of scope v1): ${method} ${url.pathname}`);
      res.writeHead(501, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_implemented", message: "PTY out of scope v1" }));
      return;
    }

    if (decision.action === "tui-501") {
      console.warn(`[FRONTDOOR WARN] TUI request denied: ${method} ${url.pathname}`);
      res.writeHead(501, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_implemented", message: "TUI endpoints are per-process; not available through the front door" }));
      return;
    }

    if (decision.action === "deny-per-process-501") {
      console.warn(`[FRONTDOOR WARN] MCP connection status request denied: ${method} ${url.pathname}`);
      res.writeHead(501, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_implemented", message: "MCP connection status is per-process; not available through the front door" }));
      return;
    }

    if (decision.action === "forward-anchor") {
      target = ctx.config.anchorUrl;
      degraded = false;
      await proxyRequest(target, method, url, req, res, ctx, null);
      return;
    }

    if (decision.action === "forward-pool") {
      degraded = false;
      const order = poolOrder(ctx.config.poolUrls, ctx.config.anchorUrl);
      for (let i = 0; i < order.length; i++) {
        target = order[i];
        const isLast = i === order.length - 1;
        const outcome = await proxyRequest(target, method, url, req, res, ctx, null, {
          failoverIfUnreachable: !isLast,
          // poolSafe routes are pool-invariant by construction, so another
          // member's answer is as good as this one's (workstation-27r8).
          failoverOnSpurious499: !isLast,
        });
        if (outcome === "completed") return;
        const nextTarget = order[i + 1];
        if (outcome === "upstream-unreachable") {
          ctx.metrics.poolFailover++;
          console.warn(
            `[FRONTDOOR WARN] pool member ${target} unreachable for ${method} ${url.pathname}; failing over to ${nextTarget}`
          );
        }
        // upstream-spurious-499: already logged and counted inside proxyRequest.
      }
      return;
    }

    if (decision.action === "create") {
      const resVal = await handleCreate(req, res, ctx, url);
      sid = resVal.sid;
      degraded = resVal.degraded;
      return;
    }

    if (decision.action === "fork") {
      const r = await handleFork(req, res, ctx, url);
      sid = r.sid;
      degraded = r.degraded;
      return;
    }

    if (decision.action === "move-session") {
      const resVal = await handleMoveSession(req, res, ctx, url);
      sid = resVal.sid;
      target = resVal.target;
      reason = resVal.reason;
      return;
    }

    if (decision.action === "route-session") {
      const ex = extractSids(url);

      if (ex.kind === "malformed") {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "bad_request", message: "Malformed session ID" }));
        return;
      }

      if (ex.kind === "none") {
        // Distinguishing from /global/event -> 410:
        // /global/event is a firehose gone from the door's contract (410);
        // bare /event is the supported endpoint missing its required scoping param (400).
        // This also removes the last degraded=true-by-policy pollution of the counter.
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "bad_request", message: "session_ids query parameter is required" }));
        return;
      }

      if (ex.kind === "single") {
        sid = ex.sid;
        const now = ctx.deps?.now?.() ?? Date.now();
        const mutating = isMutatingSessionRequest(method, url.pathname, ex);

        // 1) Sticky check BEFORE resolve/promote — mutating requests only.
        if (mutating) {
          const stuckServe = ctx.sticky.get(sid, now);
          if (stuckServe) {
            const healthy = await probeServeHealth(stuckServe, ctx.config, ctx.deps);
            if (healthy) {
              target = stuckServe; degraded = false; prospective = false;

              if (ctx.sticky.needsLeaseRenewal(sid, now)) {
                const routingSid = ctx.sticky.getRoutingSid(sid);
                if (typeof routingSid === "string") {
                  // Advance the renewal clock SYNCHRONOUSLY before the fire-and-forget
                  // /place so interleaved sticky hits within ½ TTL can't double-renew.
                  ctx.sticky.setLeaseRenewedAt(sid, now);
                  placeSession(routingSid, ctx.config, ctx.deps).then((result) => {
                    if (!result.ok) {
                      console.warn(`[FRONTDOOR WARN] lease renewal placeSession failed for sid: ${routingSid}, status: ${result.status}`);
                    } else {
                      // Log SUCCESSES too: without this, "did renewal fire?" can only be
                      // inferred from pigeon lease timing after the fact (sq1v T5 Claim B).
                      console.log(`[FRONTDOOR] lease renewal placed sid: ${routingSid}${routingSid === sid ? "" : ` (root of ${sid})`}`);
                    }
                  }).catch((err) => {
                    console.warn(`[FRONTDOOR WARN] lease renewal placeSession threw for sid: ${routingSid}`, err);
                  });
                }
              }

              ctx.sticky.record(sid, stuckServe, now); // refresh TTL
              await proxyRequest(target, method, url, req, res, ctx, ex);
              return;
            }
            ctx.sticky.delete(sid); // sticky target failed health probe → break, fall through
          }
        }

        // 2) Normal resolve/promote (existing logic, unchanged).
        const resolved = await resolveOwner(ex.sid, ctx.config, ctx.deps);
        if (resolved.viaParent) viaParent = true;
        if (resolved.routingSid !== ex.sid) routingSid = resolved.routingSid;
        const isPromoting = isPromotingRequest(method, url.pathname, ex);
        let wasPromoted = false;
        if (isPromoting) {
          const promo = await maybePromote({ sid: ex.sid, method, pathname: url.pathname, extraction: ex, resolved, gate: ctx.gate }, ctx.config, ctx.deps);
          if (promo.placed && promo.apiBase && isAbsoluteHttpUrl(promo.apiBase)) {
            target = promo.apiBase; degraded = false; prospective = false;
            wasPromoted = true;
            // vjq0: count the placements the FIX RESCUED — a state-pinning request that
            // was NOT-ROUTED and would previously have degraded to the anchor with its MCP
            // state stranded there.
            //
            // Deliberately NOT every state-pinning placement. `maybePromote` also places
            // `prospective` connects, which measured 12/week and were already safe
            // pre-fix (prospective resolves degraded:false, so the connect records sticky
            // and the following turn short-circuits to the same member). Counting those
            // would read nonzero-but-meaningless and invite the conclusion that the race
            // fires weekly. Adversarial review caught exactly that misreading.
            if (isStatePinningRequest(url.pathname) && resolved.reason === "not-routed") {
              ctx.metrics.promotedOnConnect++;
            }
          } else {
            target = resolved.url; degraded = resolved.degraded; prospective = resolved.prospective;
          }
        } else {
          target = resolved.url; degraded = resolved.degraded; prospective = resolved.prospective;
        }

        // 3) FABLE-S2 write-vs-read degrade split. A mutating request that ended up
        //    degraded because the CONTROL PLANE is down (pigeon-unreachable / -error),
        //    with no usable sticky, must NOT run on a non-owner (duplicate/wrong-process
        //    turn, abort no-ops). Return a retryable 503. Reads (and not-routed) still
        //    degrade to the anchor (shared opencode.db).
        if (mutating && degraded && (resolved.reason === "pigeon-unreachable" || resolved.reason === "pigeon-error")) {
          res.writeHead(503, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "service_unavailable", message: "pigeon unavailable; refusing to route a mutating request to a non-owner" }));
          return;
        }

        // 3b) sq1v counter: a MUTATING request we are about to forward to the anchor
        //     because neither the sid nor (after the parent walk) its root is routed.
        //     It will run on a possibly-wrong process. Deliberately counted rather
        //     than 503'd for now; tighten to a 503 once the rate is known to be ~0.
        if (mutating && degraded && resolved.reason === "not-routed") {
          ctx.metrics.notRoutedMutationToAnchor++;
        }

        // 4) Record stickiness when forwarding a mutating request to a REAL owner
        //    (never record the anchor-degrade target).
        if (mutating && !degraded) {
          // Fresh promote/place → lease is new (renewedAt=now). Active resolve of
          // unknown lease age → seed 0 so the NEXT sticky hit renews immediately.
          const leaseRenewedAt = wasPromoted ? now : 0;
          ctx.sticky.record(sid, target, now, leaseRenewedAt, resolved.routingSid);
        }

        await proxyRequest(target, method, url, req, res, ctx, ex);
        return;
      }

      if (ex.kind === "multi") {
        if (ex.sids.length > MAX_SESSION_IDS) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "bad_request", message: "too many session_ids" }));
          return;
        }

        sid = ex.sids.join(",");
        const promises = ex.sids.map(s => resolveOwner(s, ctx.config, ctx.deps));
        const resolvedList = await Promise.all(promises);

        const realOwners = resolvedList.filter(r => !r.degraded);
        const distinctRealUrls = new Set(realOwners.map(r => r.url));

        if (distinctRealUrls.size >= 2) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "bad_request", message: "Diverging owners for multi-session request" }));
          return;
        }

        if (distinctRealUrls.size === 1) {
          target = [...distinctRealUrls][0];
          prospective = realOwners.some(r => r.prospective);
          degraded = false;
        } else {
          target = ctx.config.anchorUrl;
          degraded = resolvedList.some(r => r.reason === "pigeon-unreachable" || r.reason === "pigeon-error");
          prospective = false;
        }

        await proxyRequest(target, method, url, req, res, ctx, ex);
        return;
      }
    }
  } catch (err: any) {
    console.error("[frontdoor] handleRequest error:", err);
    if (!res.headersSent) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "internal_server_error", message: err.message }));
    }
  }
}
