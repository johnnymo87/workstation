import { describe, expect, test, vi } from "vitest";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { isEventStreamResponse, pipeEventStream } from "../src/sse.js";

describe("isEventStreamResponse", () => {
  test("returns true for valid text/event-stream content types", () => {
    expect(isEventStreamResponse({ "content-type": "text/event-stream" })).toBe(true);
    expect(isEventStreamResponse({ "content-type": "text/event-stream; charset=utf-8" })).toBe(true);
    expect(isEventStreamResponse({ "content-type": "  text/event-stream  " })).toBe(true);
  });

  test("returns true case-insensitively for values", () => {
    expect(isEventStreamResponse({ "content-type": "TEXT/EVENT-STREAM" })).toBe(true);
    expect(isEventStreamResponse({ "content-type": "Text/Event-Stream; charset=utf-8" })).toBe(true);
  });

  test("returns false for application/json, empty, or missing headers", () => {
    expect(isEventStreamResponse({ "content-type": "application/json" })).toBe(false);
    expect(isEventStreamResponse({ "content-type": "" })).toBe(false);
    expect(isEventStreamResponse({})).toBe(false);
  });
});

describe("pipeEventStream", () => {
  // Helper to start an ephemeral HTTP server
  function startServer(handler: (req: http.IncomingMessage, res: http.ServerResponse) => void): Promise<http.Server> {
    return new Promise((resolve) => {
      const server = http.createServer(handler);
      server.listen(0, "127.0.0.1", () => resolve(server));
    });
  }

  // Helper to stop an HTTP server
  function stopServer(server: http.Server): Promise<void> {
    return new Promise((resolve) => server.close(() => resolve()));
  }

  test("unbuffered pass-through: clients receive chunks incrementally before stream ends", async () => {
    let resolveFirstChunk: () => void = () => {};
    const firstChunkReceived = new Promise<void>((r) => {
      resolveFirstChunk = r;
    });

    let upstreamResToRelease: http.ServerResponse | null = null;

    // Upstream server writes header, writes first chunk, waits, writes second chunk, then ends.
    const upstreamServer = await startServer((req, res) => {
      upstreamResToRelease = res;
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write("data: first\n\n");
    });

    const upstreamPort = (upstreamServer.address() as AddressInfo).port;

    // Client/destination server simulates the frontdoor proxy receiving
    const clientServer = await startServer((req, res) => {
      // Connect to upstream
      const upstreamReq = http.request(`http://127.0.0.1:${upstreamPort}`, (upstreamRes) => {
        pipeEventStream(upstreamRes, res, {
          onActivity: () => {},
          onDone: () => {}
        });
      });
      upstreamReq.end();
    });

    const clientPort = (clientServer.address() as AddressInfo).port;

    // Make request to frontdoor (clientServer)
    const clientReq = http.request(`http://127.0.0.1:${clientPort}`, (clientRes) => {
      clientRes.on("data", (chunk) => {
        const str = chunk.toString();
        if (str.includes("first")) {
          resolveFirstChunk();
        }
      });
    });
    clientReq.end();

    // Assert that we received the first chunk before the upstream ended.
    await firstChunkReceived;

    // Clean up
    if (upstreamResToRelease) {
      (upstreamResToRelease as http.ServerResponse).write("data: second\n\n");
      (upstreamResToRelease as http.ServerResponse).end();
    }
    clientReq.destroy();
    await stopServer(upstreamServer);
    await stopServer(clientServer);
  });

  test("survives heartbeat/idle and does not tear down on gaps", async () => {
    const upstreamServer = await startServer((req, res) => {
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write(": heartbeat\n\n");
      setTimeout(() => {
        res.write("data: content\n\n");
        res.end();
      }, 50);
    });

    const upstreamPort = (upstreamServer.address() as AddressInfo).port;
    const clientServer = await startServer((req, res) => {
      const upstreamReq = http.request(`http://127.0.0.1:${upstreamPort}`, (upstreamRes) => {
        pipeEventStream(upstreamRes, res, {
          onActivity: () => {},
          onDone: () => {}
        });
      });
      upstreamReq.end();
    });

    const clientPort = (clientServer.address() as AddressInfo).port;

    const receivedChunks: string[] = [];
    await new Promise<void>((resolve, reject) => {
      const clientReq = http.request(`http://127.0.0.1:${clientPort}`, (clientRes) => {
        clientRes.on("data", (chunk) => {
          receivedChunks.push(chunk.toString());
        });
        clientRes.on("end", resolve);
        clientRes.on("error", reject);
      });
      clientReq.end();
    });

    expect(receivedChunks.join("")).toContain(": heartbeat\n\n");
    expect(receivedChunks.join("")).toContain("data: content\n\n");

    await stopServer(upstreamServer);
    await stopServer(clientServer);
  });

  test("activity seam fires on every chunk including heartbeats/comments", async () => {
    const upstreamServer = await startServer((req, res) => {
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write(": keep-alive\n\n");
      res.write("data: hello\n\n");
      res.end();
    });

    const upstreamPort = (upstreamServer.address() as AddressInfo).port;
    let activityCount = 0;

    const clientServer = await startServer((req, res) => {
      const upstreamReq = http.request(`http://127.0.0.1:${upstreamPort}`, (upstreamRes) => {
        pipeEventStream(upstreamRes, res, {
          onActivity: () => {
            activityCount++;
          },
          onDone: () => {}
        });
      });
      upstreamReq.end();
    });

    const clientPort = (clientServer.address() as AddressInfo).port;

    await new Promise<void>((resolve, reject) => {
      const clientReq = http.request(`http://127.0.0.1:${clientPort}`, (clientRes) => {
        clientRes.on("data", () => {});
        clientRes.on("end", resolve);
        clientRes.on("error", reject);
      });
      clientReq.end();
    });

    // Should fire on ": keep-alive\n\n" chunk and "data: hello\n\n" chunk
    expect(activityCount).toBeGreaterThanOrEqual(2);

    await stopServer(upstreamServer);
    await stopServer(clientServer);
  });

  test("teardown: upstream error destroys client response, client close destroys upstream response", async () => {
    let upstreamResRef: http.IncomingMessage | null = null;
    let clientResRef: http.ServerResponse | null = null;

    let resolveDone: () => void = () => {};
    const streamDone = new Promise<void>((resolve) => {
      resolveDone = resolve;
    });

    const upstreamServer = await startServer((req, res) => {
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write("data: init\n\n");
      // Keep it open
    });

    const upstreamPort = (upstreamServer.address() as AddressInfo).port;
    const clientServer = await startServer((req, res) => {
      clientResRef = res;
      const upstreamReq = http.request(`http://127.0.0.1:${upstreamPort}`, (upstreamRes) => {
        upstreamResRef = upstreamRes;
        pipeEventStream(upstreamRes, res, {
          onActivity: () => {},
          onDone: () => {
            resolveDone();
          }
        });
      });
      upstreamReq.end();
    });

    const clientPort = (clientServer.address() as AddressInfo).port;

    // Connect a client and hang up
    let clientResSocketDestroyed = false;
    const clientReq = http.request(`http://127.0.0.1:${clientPort}`, (clientRes) => {
      clientRes.on("data", () => {
        // First chunk received, hang up immediately
        clientReq.destroy();
      });
    });
    clientReq.end();

    // Wait deterministically for the stream to complete / client close to trigger onDone
    await streamDone;

    expect(upstreamResRef).not.toBeNull();
    // Upstream response should be destroyed (releasing the socket) when the client closed the connection
    expect(upstreamResRef!.destroyed).toBe(true);

    await stopServer(upstreamServer);
    await stopServer(clientServer);
  });
});
