import type { IncomingMessage, ServerResponse } from "node:http";
import http from "node:http";
import https from "node:https";
import { identify } from "./identity.js";
import { dispatch } from "./dispatch.js";
import { extractSids, type SidExtraction } from "./sid.js";
import { isExemptFromFirstByteTimeout } from "./timeouts.js";
import { resolveOwner } from "./resolve.js";
import { isPromotingRequest, maybePromote, PromotionGate } from "./place.js";
import type { Config } from "./config.js";
import { RequestLogger } from "./log.js";
import { isAbsoluteHttpUrl } from "./http.js";
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
      if (!decision.recognized) {
        console.warn(`[FRONTDOOR WARN] Unrecognized pathname: ${method} ${url.pathname}`);
      }
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_found" }));
      return;
    }

    if (decision.action === "deny-405") {
      res.writeHead(405, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "method_not_allowed" }));
      return;
    }

    if (decision.action === "gone-410") {
      res.writeHead(410, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "gone" }));
      return;
    }

    if (decision.action === "pty-501") {
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
      // TODO(Phase 4): place-after-create choreography
      target = ctx.config.anchorUrl;
      degraded = false;
      await proxyRequest(target, method, url, req, res, ctx, null);
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
        const resolved = await resolveOwner(ex.sid, ctx.config, ctx.deps);

        const isPromoting = isPromotingRequest(method, url.pathname, ex);
        if (isPromoting) {
          const promo = await maybePromote({
            sid: ex.sid,
            method,
            pathname: url.pathname,
            extraction: ex,
            resolved,
            gate: ctx.gate
          }, ctx.config, ctx.deps);

          if (promo.placed && promo.apiBase && isAbsoluteHttpUrl(promo.apiBase)) {
            target = promo.apiBase;
            degraded = false;
            prospective = false;
          } else {
            target = resolved.url;
            degraded = resolved.degraded;
            prospective = resolved.prospective;
          }
        } else {
          target = resolved.url;
          degraded = resolved.degraded;
          prospective = resolved.prospective;
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
