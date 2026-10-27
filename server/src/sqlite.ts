// SQLite adapter for local development and tests (Node only).
import Database from "better-sqlite3";
import { SCHEMA, type Db, type Param, type Statement } from "./db.js";

export class SqliteDb implements Db {
  private readonly db: Database.Database;

  constructor(path = ":memory:") {
    this.db = new Database(path);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    for (const statement of SCHEMA) this.db.exec(statement);
  }

  async all<T>(sql: string, ...params: Param[]) {
    return this.db.prepare(sql).all(...params) as T[];
  }

  async get<T>(sql: string, ...params: Param[]) {
    return this.db.prepare(sql).get(...params) as T | undefined;
  }

  async run(sql: string, ...params: Param[]) {
    return { changes: this.db.prepare(sql).run(...params).changes };
  }

  async batch(statements: Statement[]) {
    this.db.transaction(() => {
      for (const s of statements) this.db.prepare(s.sql).run(...(s.params ?? []));
    })();
  }
}
