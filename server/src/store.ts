import type { Db, Statement } from "./db.js";
import type { DailyMetrics, Profile, SessionInput, WorkoutUpload } from "./schemas.js";
import { Profile as ProfileSchema } from "./schemas.js";

export interface User {
  id: string;
  appToken: string;
  connectorToken: string;
  createdAt: string;
  claudeConnectedAt: string | null;
  claudeLastSeenAt: string | null;
  profile: Profile;
}

export interface Session extends SessionInput {
  id: string;
  status: "planned" | "done" | "skipped";
  workoutId: string | null;
  updatedAt: string;
}

export interface Workout extends WorkoutUpload {
  rpe: number | null;
}

export interface Analysis {
  workoutId: string;
  text: string;
  keyPoints: { kind: "good" | "warning" | "next"; text: string }[];
  createdAt: string;
}

export interface Checkin {
  id: string;
  date: string;
  feeling: number;
  note: string | null;
  sessionId: string | null;
  createdAt: string;
}

type Row = Record<string, any>;

const now = () => new Date().toISOString();
const json = <T>(text: string | null, fallback: T): T => (text ? (JSON.parse(text) as T) : fallback);

/** Random URL-safe secret (Web Crypto: works in Node and Workers). */
function token(bytes = 24) {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  let binary = "";
  for (const b of data) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export class Store {
  constructor(private readonly db: Db) {}

  // MARK: Users

  async createUser(): Promise<User> {
    const id = crypto.randomUUID();
    await this.db.run(
      "INSERT INTO users (id, app_token, connector_token, created_at) VALUES (?, ?, ?, ?)",
      id, token(), token(), now()
    );
    return (await this.userById(id))!;
  }

  private rowToUser(row: Row | undefined): User | undefined {
    if (!row) return undefined;
    return {
      id: row.id,
      appToken: row.app_token,
      connectorToken: row.connector_token,
      createdAt: row.created_at,
      claudeConnectedAt: row.claude_connected_at,
      claudeLastSeenAt: row.claude_last_seen_at,
      profile: json(row.profile_json, {}),
    };
  }

  async userById(id: string) {
    return this.rowToUser(await this.db.get<Row>("SELECT * FROM users WHERE id = ?", id));
  }
  async userByAppToken(t: string) {
    return this.rowToUser(await this.db.get<Row>("SELECT * FROM users WHERE app_token = ?", t));
  }
  async userByConnectorToken(t: string) {
    return this.rowToUser(await this.db.get<Row>("SELECT * FROM users WHERE connector_token = ?", t));
  }

  async markClaudeSeen(userId: string) {
    const t = now();
    await this.db.run(
      "UPDATE users SET claude_last_seen_at = ?, claude_connected_at = COALESCE(claude_connected_at, ?) WHERE id = ?",
      t, t, userId
    );
  }

  async updateProfile(userId: string, patch: Profile): Promise<Profile> {
    const current = (await this.userById(userId))!.profile;
    const merged = ProfileSchema.parse({ ...current, ...patch });
    await this.db.run("UPDATE users SET profile_json = ? WHERE id = ?", JSON.stringify(merged), userId);
    return merged;
  }

  // MARK: Health data

  async upsertWorkouts(userId: string, workouts: WorkoutUpload[]) {
    const sql = `
      INSERT INTO workouts (id, user_id, sport, start, end, local_date, duration_s, distance_m, energy_kcal, avg_hr, max_hr, elevation_m, details_json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(user_id, id) DO UPDATE SET
        sport = excluded.sport, start = excluded.start, end = excluded.end, local_date = excluded.local_date,
        duration_s = excluded.duration_s, distance_m = excluded.distance_m, energy_kcal = excluded.energy_kcal,
        avg_hr = excluded.avg_hr, max_hr = excluded.max_hr, elevation_m = excluded.elevation_m, details_json = excluded.details_json`;
    await this.db.batch(
      workouts.map((w) => ({
        sql,
        params: [
          w.id, userId, w.sport, w.start, w.end, w.localDate, w.durationS,
          w.distanceM ?? null, w.energyKcal ?? null, w.avgHr ?? null, w.maxHr ?? null, w.elevationM ?? null,
          JSON.stringify(w.details ?? {}),
        ],
      }))
    );
    await this.linkWorkoutsToSessions(userId);
  }

  private rowToWorkout(r: Row): Workout {
    return {
      id: r.id,
      sport: r.sport,
      start: r.start,
      end: r.end,
      localDate: r.local_date,
      durationS: r.duration_s,
      distanceM: r.distance_m,
      energyKcal: r.energy_kcal,
      avgHr: r.avg_hr,
      maxHr: r.max_hr,
      elevationM: r.elevation_m,
      details: json(r.details_json, {}),
      rpe: r.rpe,
    };
  }

  async listWorkouts(userId: string, opts: { from?: string; to?: string; sport?: string; limit?: number } = {}) {
    const rows = await this.db.all<Row>(
      `SELECT * FROM workouts WHERE user_id = ?
       AND (? IS NULL OR local_date >= ?) AND (? IS NULL OR local_date <= ?) AND (? IS NULL OR sport = ?)
       ORDER BY start DESC LIMIT ?`,
      userId, opts.from ?? null, opts.from ?? null, opts.to ?? null, opts.to ?? null, opts.sport ?? null, opts.sport ?? null, opts.limit ?? 500
    );
    return rows.map((r) => this.rowToWorkout(r));
  }

  async workout(userId: string, id: string) {
    const r = await this.db.get<Row>("SELECT * FROM workouts WHERE user_id = ? AND id = ?", userId, id);
    return r ? this.rowToWorkout(r) : undefined;
  }

  async setRpe(userId: string, workoutId: string, rpe: number) {
    return (await this.db.run("UPDATE workouts SET rpe = ? WHERE user_id = ? AND id = ?", rpe, userId, workoutId)).changes > 0;
  }

  async upsertDailyMetrics(userId: string, items: DailyMetrics[]) {
    const sql = `
      INSERT INTO daily_metrics (user_id, date, sleep_min, hrv_ms, resting_hr, vo2max)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(user_id, date) DO UPDATE SET
        sleep_min = COALESCE(excluded.sleep_min, sleep_min), hrv_ms = COALESCE(excluded.hrv_ms, hrv_ms),
        resting_hr = COALESCE(excluded.resting_hr, resting_hr), vo2max = COALESCE(excluded.vo2max, vo2max)`;
    await this.db.batch(
      items.map((m) => ({ sql, params: [userId, m.date, m.sleepMin ?? null, m.hrvMs ?? null, m.restingHr ?? null, m.vo2max ?? null] }))
    );
  }

  async dailyMetrics(userId: string, days: number, timeZone = "UTC"): Promise<DailyMetrics[]> {
    const from = isoDate(addDays(new Date(), -days), timeZone);
    const rows = await this.db.all<Row>("SELECT * FROM daily_metrics WHERE user_id = ? AND date >= ? ORDER BY date DESC", userId, from);
    return rows.map((r) => ({ date: r.date, sleepMin: r.sleep_min, hrvMs: r.hrv_ms, restingHr: r.resting_hr, vo2max: r.vo2max }));
  }

  // MARK: Plan

  async upsertSessions(userId: string, sessions: SessionInput[]): Promise<Session[]> {
    const sql = `
      INSERT INTO sessions (id, user_id, date, json, updated_at) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET date = excluded.date, json = excluded.json, updated_at = excluded.updated_at
      WHERE sessions.user_id = excluded.user_id`;
    const ids: string[] = [];
    const statements: Statement[] = sessions.map((s) => {
      const id = s.id ?? crypto.randomUUID();
      const { id: _ignored, ...body } = s;
      ids.push(id);
      return { sql, params: [id, userId, s.date, JSON.stringify(body), now()] };
    });
    await this.db.batch(statements);
    await this.linkWorkoutsToSessions(userId);
    const saved = await Promise.all(ids.map((id) => this.session(userId, id)));
    return saved.filter((s): s is Session => !!s);
  }

  async deleteSessions(userId: string, ids: string[]) {
    let count = 0;
    for (const id of ids) count += (await this.db.run("DELETE FROM sessions WHERE user_id = ? AND id = ?", userId, id)).changes;
    return count;
  }

  private rowToSession(r: Row): Session {
    return { ...json<SessionInput>(r.json, {} as SessionInput), id: r.id, date: r.date, status: r.status, workoutId: r.workout_id, updatedAt: r.updated_at };
  }

  async session(userId: string, id: string) {
    const r = await this.db.get<Row>("SELECT * FROM sessions WHERE user_id = ? AND id = ?", userId, id);
    return r ? this.rowToSession(r) : undefined;
  }

  async sessions(userId: string, from?: string, to?: string): Promise<Session[]> {
    const rows = await this.db.all<Row>(
      "SELECT * FROM sessions WHERE user_id = ? AND (? IS NULL OR date >= ?) AND (? IS NULL OR date <= ?) ORDER BY date",
      userId, from ?? null, from ?? null, to ?? null, to ?? null
    );
    return rows.map((r) => this.rowToSession(r));
  }

  /** A planned session is "done" when a workout of the same sport happened that day. */
  private async linkWorkoutsToSessions(userId: string) {
    const planned = (await this.db.all<Row>("SELECT * FROM sessions WHERE user_id = ? AND workout_id IS NULL", userId)).map((r) => this.rowToSession(r));
    for (const s of planned) {
      if (s.sport === "repos") continue;
      const w = await this.db.get<{ id: string }>(
        `SELECT id FROM workouts WHERE user_id = ? AND sport = ? AND local_date = ?
         AND id NOT IN (SELECT workout_id FROM sessions WHERE user_id = ? AND workout_id IS NOT NULL)
         ORDER BY duration_s DESC LIMIT 1`,
        userId, s.sport, s.date, userId
      );
      if (w) await this.db.run("UPDATE sessions SET workout_id = ?, status = 'done' WHERE id = ?", w.id, s.id);
    }
  }

  // MARK: Coach writings

  async setNote(userId: string, date: string, text: string) {
    await this.db.run(
      "INSERT INTO notes (user_id, date, text, created_at) VALUES (?, ?, ?, ?) ON CONFLICT(user_id, date) DO UPDATE SET text = excluded.text, created_at = excluded.created_at",
      userId, date, text, now()
    );
  }

  async note(userId: string, date: string) {
    const r = await this.db.get<Row>("SELECT * FROM notes WHERE user_id = ? AND date = ?", userId, date);
    return r ? { date: r.date as string, text: r.text as string, createdAt: r.created_at as string } : null;
  }

  async setAnalysis(userId: string, workoutId: string, text: string, keyPoints: Analysis["keyPoints"]) {
    await this.db.run(
      "INSERT INTO analyses (user_id, workout_id, text, key_points_json, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(user_id, workout_id) DO UPDATE SET text = excluded.text, key_points_json = excluded.key_points_json, created_at = excluded.created_at",
      userId, workoutId, text, JSON.stringify(keyPoints), now()
    );
  }

  async analyses(userId: string, workoutIds?: string[]): Promise<Analysis[]> {
    const rows = await this.db.all<Row>("SELECT * FROM analyses WHERE user_id = ?", userId);
    return rows
      .filter((r) => !workoutIds || workoutIds.includes(r.workout_id))
      .map((r) => ({ workoutId: r.workout_id, text: r.text, keyPoints: json(r.key_points_json, []), createdAt: r.created_at }));
  }

  // MARK: Check-ins

  async addCheckin(userId: string, c: { date: string; feeling: number; note?: string | null; sessionId?: string | null }): Promise<Checkin> {
    const item: Checkin = { id: crypto.randomUUID(), date: c.date, feeling: c.feeling, note: c.note ?? null, sessionId: c.sessionId ?? null, createdAt: now() };
    await this.db.run(
      "INSERT INTO checkins (id, user_id, date, feeling, note, session_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      item.id, userId, item.date, item.feeling, item.note, item.sessionId, item.createdAt
    );
    return item;
  }

  async checkins(userId: string, days: number, timeZone = "UTC"): Promise<Checkin[]> {
    const from = isoDate(addDays(new Date(), -days), timeZone);
    const rows = await this.db.all<Row>("SELECT * FROM checkins WHERE user_id = ? AND date >= ? ORDER BY created_at DESC", userId, from);
    return rows.map((r) => ({ id: r.id, date: r.date, feeling: r.feeling, note: r.note, sessionId: r.session_id, createdAt: r.created_at }));
  }
}

export function isoDate(d: Date, timeZone = "UTC") {
  // en-CA formats as YYYY-MM-DD
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}

export function addDays(d: Date, n: number) {
  const copy = new Date(d);
  copy.setUTCDate(copy.getUTCDate() + n);
  return copy;
}
