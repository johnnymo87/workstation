import type { IncomingMessage, ServerResponse } from "node:http";
import http from "node:http";
import https from "node:https";
import { identify } from "./identity.js";
import { dispatch } from "./dispatch.js";
import { extractSids, type SidExtraction, SID_REGEX, extractSessionIdFromPath } from "./sid.js";
import { isExemptFromFirstByteTimeout } from "./timeouts.js";
import { resolveOwner } from "./resolve.js";
import { isPromotingRequest, maybePromote, PromotionGate, placeSession } from "./place.js";
import { StickyMap, isMutatingSessionRequest, sidsForStickiness } from "./sticky.js";
import { probeServeHealth } from "./health.js";
import type { Config } from "./config.js";
import { RequestLogger } from "./log.js";
import { isAbsoluteHttpUrl, boundedFetch, stripTrailingSlashes } from "./http.js";
import { isEventStreamResponse, pipeEventStream } from "./sse.js";
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

async function proxyRequest(
  target: string,
  method: string,
  url: URL,
  req: IncomingMessage,
  res: ServerResponse,
  ctx: ProxyContext,
  extraction: SidExtraction | null
): Promise<void> {
  return new Promise<void>((resolve) => {
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

    const path = targetParsed.pathname.replace(/\/+$/, "") + url.pathname + url.search;

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

    const safeResolve = () => {
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
      resolve();
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
          upstreamReq.destroy();
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
      if (cheapTimeoutId) {
        clearTimeout(cheapTimeoutId);
        cheapTimeoutId = null;
      }
      if (wedgeProbe) {
        wedgeProbe.stop();
        wedgeProbe = null;
      }
      if (res.headersSent || headersSent) {
        upstreamRes.resume(); // drain to release the socket back to the pool
        return;
      }
      headersSent = true;

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
      if (!headersSent && !res.headersSent) {
        res.writeHead(502, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "bad_gateway", message: err.message }));
      } else if (!res.writableEnded) {
        // Avoid an abrupt RST that races the already-flushed response (e.g. the
        // 503 first-byte-timeout path calls upstreamReq.destroy(), which can
        // surface here after res.end()). Only tear down if still writable.
        res.destroy();
      }
      safeResolve();
    });

    req.pipe(upstreamReq);

    res.on("close", () => {
      if (!res.writableEnded) {
        upstreamReq.destroy();
      }
      safeResolve();
    });
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

  const targetBase = stripTrailingSlashes(target);
  const targetUrl = `${targetBase}${url.pathname}${url.search}`;

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

  if (response.status < 200 || response.status >= 300) {
    const anchorBody = await response.text();
    const responseHeaders = forwardableResponseHeaders(response.headers);
    res.writeHead(response.status, responseHeaders);
    res.end(anchorBody);
    return { sid: null, degraded: false };
  }

  const anchorBody = await response.text();
  let parsedSid: string | undefined;
  try {
    const parsed = JSON.parse(anchorBody);
    if (parsed && typeof parsed === "object" && typeof parsed.id === "string") {
      parsedSid = parsed.id;
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

  const placeResult = await placeSession(parsedSid, ctx.config, ctx.deps);

  if (placeResult.ok) {
    const now = ctx.deps?.now?.() ?? Date.now();
    if (placeResult.apiBase && isAbsoluteHttpUrl(placeResult.apiBase)) {
      ctx.sticky.record(parsedSid, placeResult.apiBase, now);
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
      status: res.statusCode || 200,
      durationMs,
      method,
      path: url.pathname
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
          message: "The web UI is not served through the front door. Use a serve port directly."
        }));
      } else {
        console.warn(`[FRONTDOOR WARN] Unrecognized pathname: ${method} ${url.pathname}`);
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "not_found" }));
      }
      return;
    }

    if (decision.action === "deny-global-mutation") {
      if (decision.allowedMethods.length > 0) {
        const allowedJoined = decision.allowedMethods.join(", ");
        console.warn(`[FRONTDOOR WARN] Global mutation not proxied through the front door (405): ${method} ${url.pathname}`);
        res.writeHead(405, {
          "Content-Type": "application/json",
          "Allow": allowedJoined
        });
        res.end(JSON.stringify({
          error: "method_not_allowed_through_frontdoor",
          message: `${method} ${url.pathname} mutates per-process state and is not proxied through the front door. Allowed through the door: ${allowedJoined}. To mutate, call a serve port directly.`
        }));
      } else {
        console.warn(`[FRONTDOOR WARN] Global mutation not proxied through the front door (403): ${method} ${url.pathname}`);
        res.writeHead(403, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          error: "forbidden_through_frontdoor",
          message: `${method} ${url.pathname} is not proxied through the front door (mutates per-process/single-process state). Call a serve port directly.`
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

    if (decision.action === "forward-anchor") {
      target = ctx.config.anchorUrl;
      degraded = false;
      await proxyRequest(target, method, url, req, res, ctx, null);
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
                // Advance the renewal clock SYNCHRONOUSLY before the fire-and-forget
                // /place so interleaved sticky hits within ½ TTL can't double-renew.
                ctx.sticky.setLeaseRenewedAt(sid, now);
                placeSession(sid, ctx.config, ctx.deps).then((result) => {
                  if (!result.ok) {
                    console.warn(`[FRONTDOOR WARN] lease renewal placeSession failed for sid: ${sid}, status: ${result.status}`);
                  }
                }).catch((err) => {
                  console.warn(`[FRONTDOOR WARN] lease renewal placeSession threw for sid: ${sid}`, err);
                });
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
        const isPromoting = isPromotingRequest(method, url.pathname, ex);
        let wasPromoted = false;
        if (isPromoting) {
          const promo = await maybePromote({ sid: ex.sid, method, pathname: url.pathname, extraction: ex, resolved, gate: ctx.gate }, ctx.config, ctx.deps);
          if (promo.placed && promo.apiBase && isAbsoluteHttpUrl(promo.apiBase)) {
            target = promo.apiBase; degraded = false; prospective = false;
            wasPromoted = true;
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

        // 4) Record stickiness when forwarding a mutating request to a REAL owner
        //    (never record the anchor-degrade target).
        if (mutating && !degraded) {
          // Fresh promote/place → lease is new (renewedAt=now). Active resolve of
          // unknown lease age → seed 0 so the NEXT sticky hit renews immediately.
          const leaseRenewedAt = wasPromoted ? now : 0;
          ctx.sticky.record(sid, target, now, leaseRenewedAt);
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
