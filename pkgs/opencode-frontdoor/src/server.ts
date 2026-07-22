import http from "node:http";
import { loadConfig, type Config } from "./config.js";
import { handleRequest } from "./proxy.js";
import { RequestLogger } from "./log.js";
import { PromotionGate } from "./place.js";
import { createMetrics } from "./metrics.js";
import { isHealthzRequest, handleHealthz } from "./healthz.js";
import { StickyMap } from "./sticky.js";
import { installCrashHandlers } from "./crash.js";

export function createFrontDoor(config: Config, deps?: any): http.Server {
  const logger = new RequestLogger(deps?.logger);
  const gate = new PromotionGate(config.stickyTtlMs);
  const metrics = createMetrics();
  const sticky = new StickyMap(config.stickyTtlMs);

  return http.createServer(async (req, res) => {
    try {
      const { pathname } = new URL(req.url || "", "http://internal");
      const method = req.method || "GET";
      if (isHealthzRequest(method, pathname)) {
        await handleHealthz(res, { config, method, deps, metrics });
        return;
      }
      await handleRequest(req, res, { config, logger, gate, metrics, sticky, deps });
    } catch (err: any) {
      if (!res.headersSent) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "internal_server_error", message: err.message }));
      }
      console.error("[FRONTDOOR ERROR]", err);
    }
  });
}

export function start(config: Config = loadConfig()): http.Server {
  installCrashHandlers();
  const server = createFrontDoor(config);
  server.listen(config.port, "127.0.0.1", () => {
    console.log(`[FRONTDOOR] Listening on http://127.0.0.1:${config.port}`);
  });
  return server;
}
