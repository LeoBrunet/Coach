// Local / self-hosted entry point: Node + SQLite file.
import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { SqliteDb } from "./sqlite.js";
import { Store } from "./store.js";

const port = Number(process.env.PORT ?? 8787);
const store = new Store(new SqliteDb(process.env.DATABASE_PATH ?? "coach.db"));
const app = createApp(() => store, { publicUrl: process.env.PUBLIC_URL, logRequests: !!process.env.LOG_REQUESTS });

serve({ fetch: app.fetch, port }, () => {
  console.log(`Coach server on :${port} (public URL: ${process.env.PUBLIC_URL ?? "request origin"})`);
});
