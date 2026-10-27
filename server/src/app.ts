import { Hono } from "hono";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { apiRouter } from "./api.js";
import { buildMcpServer } from "./mcp.js";
import type { Store, User } from "./store.js";

/**
 * The whole server as a fetch-style app (runs on Node and on Cloudflare Workers).
 * `publicUrl` defaults to the origin of the incoming request.
 */
export function createApp(getStore: (env: unknown) => Store, options: { publicUrl?: string; logRequests?: boolean } = {}) {
  const app = new Hono<{ Variables: { user: User; store: Store; publicUrl: string } }>();

  app.use("*", async (c, next) => {
    const started = Date.now();
    c.set("store", getStore(c.env));
    c.set("publicUrl", options.publicUrl ?? new URL(c.req.url).origin);
    await next();
    if (options.logRequests) {
      console.log(`${c.req.method} ${c.req.path.replace(/\/mcp\/[^/]+/, "/mcp/…")} ${c.res.status} ${Date.now() - started}ms`);
    }
  });

  app.get("/health", (c) => c.json({ ok: true }));
  app.route("/api", apiRouter());

  // MCP connector for Claude (streamable HTTP, stateless). The secret token in the URL identifies the athlete.
  app.post("/mcp/:token", async (c) => {
    const store = c.var.store;
    const user = await store.userByConnectorToken(c.req.param("token"));
    if (!user) return c.json({ jsonrpc: "2.0", error: { code: -32001, message: "Unknown connector" }, id: null }, 404);
    await store.markClaudeSeen(user.id);
    const server = buildMcpServer(store, user);
    const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    await server.connect(transport);
    return transport.handleRequest(c.req.raw);
  });

  const notAllowed = () =>
    new Response(JSON.stringify({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed" }, id: null }), {
      status: 405,
      headers: { "content-type": "application/json" },
    });
  app.get("/mcp/:token", notAllowed);
  app.delete("/mcp/:token", notAllowed);

  return app;
}
