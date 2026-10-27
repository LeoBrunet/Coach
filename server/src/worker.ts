// Cloudflare Workers entry point: same app, data in D1 (SQLite).
import { createApp } from "./app.js";
import { D1Db, SCHEMA, type D1DatabaseLike } from "./db.js";
import { Store } from "./store.js";

interface Env {
  DB: D1DatabaseLike & { exec(sql: string): Promise<unknown> };
  PUBLIC_URL?: string;
}

let schemaReady: Promise<void> | undefined;

/** Creates the tables on first use (idempotent), once per isolate. */
function ensureSchema(env: Env) {
  schemaReady ??= (async () => {
    await env.DB.batch(SCHEMA.map((statement) => env.DB.prepare(statement)));
  })().catch((error) => {
    schemaReady = undefined;
    throw error;
  });
  return schemaReady;
}

const app = createApp((env) => new Store(new D1Db((env as Env).DB)));

export default {
  async fetch(request: Request, env: Env, ctx: unknown) {
    await ensureSchema(env);
    return app.fetch(request, env, ctx as never);
  },
};
