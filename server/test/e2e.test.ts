import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { serve, type ServerType } from "@hono/node-server";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createApp } from "../src/app.js";
import { SqliteDb } from "../src/sqlite.js";
import { Store, isoDate } from "../src/store.js";

let server: ServerType | undefined;
// Set COACH_TEST_URL to run the same scenario against another deployment (e.g. `wrangler dev`).
let base = process.env.COACH_TEST_URL ?? "";

beforeAll(async () => {
  if (base) return;
  const store = new Store(new SqliteDb(":memory:"));
  const app = createApp(() => store);
  await new Promise<void>((resolve) => {
    server = serve({ fetch: app.fetch, port: 0 }, (info) => {
      base = `http://127.0.0.1:${info.port}`;
      resolve();
    });
  });
});

afterAll(() => server?.close());

const call = async (path: string, init: RequestInit & { token?: string } = {}) => {
  const res = await fetch(base + path, {
    ...init,
    headers: { "content-type": "application/json", ...(init.token ? { authorization: `Bearer ${init.token}` } : {}) },
  });
  return { status: res.status, body: await res.json() };
};

describe("app ↔ server ↔ Claude", () => {
  it("runs the whole loop", async () => {
    // 1. App registers and gets its connector URL.
    const reg = await call("/api/register", { method: "POST" });
    expect(reg.status).toBe(201);
    const { appToken, connectorUrl } = reg.body;
    expect(connectorUrl).toMatch(/\/mcp\/[\w-]+$/);

    const unauthorized = await call("/api/state");
    expect(unauthorized.status).toBe(401);

    // 2. App sets the time zone and syncs Health data.
    await call("/api/profile", { method: "PATCH", token: appToken, body: JSON.stringify({ timezone: "Europe/Paris" }) });
    const today = isoDate(new Date(), "Europe/Paris");
    const sync = await call("/api/sync", {
      method: "POST",
      token: appToken,
      body: JSON.stringify({
        workouts: [
          {
            id: "W1", sport: "course", start: new Date().toISOString(), end: new Date().toISOString(), localDate: today,
            durationS: 3250, distanceM: 10400, energyKcal: 712, avgHr: 151, maxHr: 178,
            details: { laps: [{ index: 1, durationS: 196, distanceM: 800 }], zonesMin: [8, 15, 6, 20, 5] },
          },
        ],
        dailyMetrics: [{ date: today, sleepMin: 462, hrvMs: 68, restingHr: 48, vo2max: 48.6 }],
      }),
    });
    expect(sync.body).toEqual({ workouts: 1, dailyMetrics: 1 });

    // 3. Claude connects through MCP.
    const client = new Client({ name: "claude-test", version: "1.0.0" });
    await client.connect(new StreamableHTTPClientTransport(new URL(connectorUrl)));
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name)).toEqual(
      expect.arrayContaining(["get_athlete_overview", "upsert_sessions", "set_daily_note", "write_workout_analysis", "get_workout"])
    );
    expect(client.getInstructions()).toContain("coach");

    const overview = await client.callTool({ name: "get_athlete_overview", arguments: {} });
    const overviewData = JSON.parse((overview.content as any)[0].text);
    expect(overviewData.today).toBe(today);
    expect(overviewData.volumeLast4Weeks.bySport.course.km).toBe(10.4);

    const upsert = await client.callTool({
      name: "upsert_sessions",
      arguments: {
        sessions: [
          {
            date: today, sport: "course", title: "Fractionné 6 × 800 m", durationMin: 55, load: "Élevée",
            why: "VMA", cues: [{ title: "4:05 /km sur chaque 800 m" }],
            target: { paceSecPerKm: 245, hrMin: 165, hrMax: 172 },
            steps: [
              { name: "Échauffement", kind: "warmup", zone: 2, durationMin: 15 },
              { name: "6 × 800 m", kind: "work", zone: 4, distanceM: 800, repeat: 6, recovery: { durationMin: 2, zone: 1 }, target: { paceSecPerKm: 245 } },
              { name: "Retour au calme", kind: "cooldown", zone: 1, durationMin: 10 },
            ],
          },
        ],
      },
    });
    expect(upsert.isError).toBeFalsy();

    await client.callTool({ name: "set_daily_note", arguments: { text: "Belle nuit, on garde le fractionné." } });
    await client.callTool({
      name: "write_workout_analysis",
      arguments: { workoutId: "W1", text: "Très bonne séance.", keyPoints: [{ kind: "good", text: "Allure tenue" }] },
    });
    const missing = await client.callTool({ name: "write_workout_analysis", arguments: { workoutId: "nope", text: "x" } });
    expect(missing.isError).toBe(true);
    await client.close();

    // 4. App sees what Claude wrote.
    await call("/api/workouts/W1/rpe", { method: "PUT", token: appToken, body: JSON.stringify({ rpe: 7 }) });
    await call("/api/checkins", { method: "POST", token: appToken, body: JSON.stringify({ date: today, feeling: 4 }) });
    const state = await call("/api/state", { token: appToken });
    expect(state.status).toBe(200);
    expect(state.body.claude.connectedAt).toBeTruthy();
    expect(state.body.note.text).toContain("fractionné");
    expect(state.body.sessions).toHaveLength(1);
    expect(state.body.sessions[0]).toMatchObject({ status: "done", workoutId: "W1", title: "Fractionné 6 × 800 m" });
    expect(state.body.sessions[0].steps[1]).toMatchObject({ repeat: 6, recovery: { durationMin: 2, zone: 1 } });
    expect(state.body.analyses[0]).toMatchObject({ workoutId: "W1", keyPoints: [{ kind: "good" }] });
    expect(state.body.rpe).toEqual({ W1: 7 });
    expect(state.body.checkins[0].feeling).toBe(4);
  });

  it("rejects unknown connectors", async () => {
    const res = await fetch(`${base}/mcp/not-a-token`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
    });
    expect(res.status).toBe(404);
  });
});
