import { Hono, type Context } from "hono";
import * as z from "zod";
import { DailyMetrics, Profile, WorkoutUpload } from "./schemas.js";
import { addDays, isoDate, type Store, type User } from "./store.js";

type Env = { Variables: { user: User; store: Store; publicUrl: string } };

export function connectorUrl(publicUrl: string, user: User) {
  return `${publicUrl.replace(/\/$/, "")}/mcp/${user.connectorToken}`;
}

async function parse<T>(c: Context, schema: z.ZodType<T>): Promise<T | Response> {
  const body = await c.req.json().catch(() => undefined);
  const result = schema.safeParse(body);
  if (!result.success) return c.json({ error: "invalid_body", issues: result.error.issues }, 400);
  return result.data;
}

/** REST API used by the iOS app. Auth: `Authorization: Bearer <appToken>`. */
export function apiRouter() {
  const api = new Hono<Env>();

  // Anonymous registration: one account per app install.
  api.post("/register", async (c) => {
    const user = await c.var.store.createUser();
    return c.json({ appToken: user.appToken, connectorUrl: connectorUrl(c.var.publicUrl, user) }, 201);
  });

  api.use("*", async (c, next) => {
    const header = c.req.header("authorization") ?? "";
    const user = header.startsWith("Bearer ") ? await c.var.store.userByAppToken(header.slice(7)) : undefined;
    if (!user) return c.json({ error: "unauthorized" }, 401);
    c.set("user", user);
    await next();
  });

  api.get("/me", (c) => {
    const user = c.var.user;
    return c.json({
      connectorUrl: connectorUrl(c.var.publicUrl, user),
      claude: { connectedAt: user.claudeConnectedAt, lastSeenAt: user.claudeLastSeenAt },
      profile: user.profile,
    });
  });

  /** Everything the app needs to render, for a date window (defaults: -180 days … +400 days, i.e. the whole plan). */
  api.get("/state", async (c) => {
    const { user, store } = c.var;
    const tz = user.profile.timezone ?? "UTC";
    const today = isoDate(new Date(), tz);
    const from = c.req.query("from") ?? isoDate(addDays(new Date(), -180), tz);
    const to = c.req.query("to") ?? isoDate(addDays(new Date(), 400), tz);
    const [sessions, workouts, note, checkins] = await Promise.all([
      store.sessions(user.id, from, to),
      store.listWorkouts(user.id, { from, to }),
      store.note(user.id, today),
      store.checkins(user.id, 14, tz),
    ]);
    const analyses = await store.analyses(user.id, workouts.map((w) => w.id));
    return c.json({
      today,
      connectorUrl: connectorUrl(c.var.publicUrl, user),
      claude: { connectedAt: user.claudeConnectedAt, lastSeenAt: user.claudeLastSeenAt },
      profile: user.profile,
      sessions,
      note,
      analyses,
      rpe: Object.fromEntries(workouts.filter((w) => w.rpe != null).map((w) => [w.id, w.rpe])),
      checkins,
    });
  });

  api.patch("/profile", async (c) => {
    const patch = await parse(c, Profile);
    if (patch instanceof Response) return patch;
    return c.json(await c.var.store.updateProfile(c.var.user.id, patch));
  });

  /** Health data pushed by the app from HealthKit. */
  api.post("/sync", async (c) => {
    const body = await parse(
      c,
      z.object({ workouts: z.array(WorkoutUpload).default([]), dailyMetrics: z.array(DailyMetrics).default([]) })
    );
    if (body instanceof Response) return body;
    await c.var.store.upsertWorkouts(c.var.user.id, body.workouts);
    await c.var.store.upsertDailyMetrics(c.var.user.id, body.dailyMetrics);
    return c.json({ workouts: body.workouts.length, dailyMetrics: body.dailyMetrics.length });
  });

  api.post("/checkins", async (c) => {
    const body = await parse(
      c,
      z.object({
        date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
        feeling: z.number().int().min(1).max(5),
        note: z.string().max(1000).nullish(),
        sessionId: z.string().nullish(),
      })
    );
    if (body instanceof Response) return body;
    return c.json(await c.var.store.addCheckin(c.var.user.id, body), 201);
  });

  api.put("/workouts/:id/rpe", async (c) => {
    const body = await parse(c, z.object({ rpe: z.number().int().min(1).max(10) }));
    if (body instanceof Response) return body;
    if (!(await c.var.store.setRpe(c.var.user.id, c.req.param("id"), body.rpe))) return c.json({ error: "workout_not_synced" }, 404);
    return c.json({ ok: true });
  });

  return api;
}
