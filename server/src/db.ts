// Minimal async database interface, implemented by SQLite (local / Node) and Cloudflare D1.

export type Param = string | number | null;

export interface Statement {
  sql: string;
  params?: Param[];
}

export interface Db {
  all<T = Record<string, unknown>>(sql: string, ...params: Param[]): Promise<T[]>;
  get<T = Record<string, unknown>>(sql: string, ...params: Param[]): Promise<T | undefined>;
  run(sql: string, ...params: Param[]): Promise<{ changes: number }>;
  /** Runs statements atomically (a transaction / D1 batch). */
  batch(statements: Statement[]): Promise<void>;
}

// MARK: Cloudflare D1

interface D1PreparedStatementLike {
  bind(...values: unknown[]): D1PreparedStatementLike;
  all<T>(): Promise<{ results: T[] }>;
  first<T>(): Promise<T | null>;
  run(): Promise<{ meta: { changes?: number } }>;
}

export interface D1DatabaseLike {
  prepare(sql: string): D1PreparedStatementLike;
  batch(statements: D1PreparedStatementLike[]): Promise<unknown>;
}

export class D1Db implements Db {
  constructor(private readonly d1: D1DatabaseLike) {}

  private stmt(sql: string, params: Param[]) {
    const prepared = this.d1.prepare(sql);
    return params.length ? prepared.bind(...params) : prepared;
  }

  async all<T>(sql: string, ...params: Param[]) {
    return (await this.stmt(sql, params).all<T>()).results;
  }

  async get<T>(sql: string, ...params: Param[]) {
    return (await this.stmt(sql, params).first<T>()) ?? undefined;
  }

  async run(sql: string, ...params: Param[]) {
    const result = await this.stmt(sql, params).run();
    return { changes: result.meta.changes ?? 0 };
  }

  async batch(statements: Statement[]) {
    if (statements.length === 0) return;
    // D1 batches are transactional; keep them reasonably small.
    for (let i = 0; i < statements.length; i += 50) {
      await this.d1.batch(statements.slice(i, i + 50).map((s) => this.stmt(s.sql, s.params ?? [])));
    }
  }
}

export const SCHEMA: string[] = [
  `CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    app_token TEXT UNIQUE NOT NULL,
    connector_token TEXT UNIQUE NOT NULL,
    created_at TEXT NOT NULL,
    claude_connected_at TEXT,
    claude_last_seen_at TEXT,
    profile_json TEXT NOT NULL DEFAULT '{}'
  )`,
  `CREATE TABLE IF NOT EXISTS workouts (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sport TEXT NOT NULL,
    start TEXT NOT NULL,
    end TEXT NOT NULL,
    local_date TEXT NOT NULL,
    duration_s REAL NOT NULL,
    distance_m REAL,
    energy_kcal REAL,
    avg_hr REAL,
    max_hr REAL,
    elevation_m REAL,
    details_json TEXT NOT NULL DEFAULT '{}',
    rpe INTEGER,
    PRIMARY KEY (user_id, id)
  )`,
  `CREATE INDEX IF NOT EXISTS workouts_by_date ON workouts(user_id, local_date)`,
  `CREATE TABLE IF NOT EXISTS daily_metrics (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    sleep_min REAL, hrv_ms REAL, resting_hr REAL, vo2max REAL,
    PRIMARY KEY (user_id, date)
  )`,
  `CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    json TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'planned',
    workout_id TEXT,
    updated_at TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS sessions_by_date ON sessions(user_id, date)`,
  `CREATE TABLE IF NOT EXISTS notes (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    text TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (user_id, date)
  )`,
  `CREATE TABLE IF NOT EXISTS analyses (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    workout_id TEXT NOT NULL,
    text TEXT NOT NULL,
    key_points_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    PRIMARY KEY (user_id, workout_id)
  )`,
  `CREATE TABLE IF NOT EXISTS checkins (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    feeling INTEGER NOT NULL,
    note TEXT,
    session_id TEXT,
    created_at TEXT NOT NULL
  )`,
];
