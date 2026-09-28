import { mkdirSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import Database from "better-sqlite3";
import { srcPath } from "../paths.js";

export type SqlParams = unknown[] | Record<string, unknown>;

export interface RunInfo {
  changes: number;
  lastInsertRowid: number | bigint;
}

/**
 * Synchronous access to the Town Hall database. Every state change runs inside `tx()`;
 * hooks let the event log publish only after a successful commit.
 */
export interface Db {
  run(sql: string, params?: SqlParams): RunInfo;
  get<T>(sql: string, params?: SqlParams): T | undefined;
  all<T>(sql: string, params?: SqlParams): T[];
  exec(sql: string): void;
  /** Runs `fn` in a transaction. Nested calls join the outer transaction. */
  tx<T>(fn: () => T): T;
  inTx(): boolean;
  /** Called once per outermost transaction, just before COMMIT (may still write). */
  addBeforeCommit(fn: () => void): void;
  addAfterCommit(fn: () => void): void;
  addAfterRollback(fn: () => void): void;
  close(): void;
  readonly file: string;
}

function bind(params?: SqlParams): unknown[] {
  if (params === undefined) return [];
  return Array.isArray(params) ? params : [params];
}

class SqliteDb implements Db {
  private readonly raw: Database.Database;
  private readonly statements = new Map<string, Database.Statement>();
  private depth = 0;
  private readonly beforeCommit: Array<() => void> = [];
  private readonly afterCommit: Array<() => void> = [];
  private readonly afterRollback: Array<() => void> = [];

  constructor(readonly file: string) {
    if (file !== ":memory:") mkdirSync(path.dirname(file), { recursive: true });
    this.raw = new Database(file);
    this.raw.pragma("journal_mode = WAL");
    this.raw.pragma("synchronous = NORMAL");
    this.raw.pragma("foreign_keys = ON");
    this.raw.pragma("busy_timeout = 5000");
  }

  private stmt(sql: string): Database.Statement {
    let s = this.statements.get(sql);
    if (!s) {
      s = this.raw.prepare(sql);
      this.statements.set(sql, s);
    }
    return s;
  }

  run(sql: string, params?: SqlParams): RunInfo {
    const r = this.stmt(sql).run(...bind(params));
    return { changes: r.changes, lastInsertRowid: r.lastInsertRowid };
  }

  get<T>(sql: string, params?: SqlParams): T | undefined {
    return this.stmt(sql).get(...bind(params)) as T | undefined;
  }

  all<T>(sql: string, params?: SqlParams): T[] {
    return this.stmt(sql).all(...bind(params)) as T[];
  }

  exec(sql: string): void {
    this.raw.exec(sql);
  }

  inTx(): boolean {
    return this.depth > 0;
  }

  addBeforeCommit(fn: () => void): void {
    this.beforeCommit.push(fn);
  }

  addAfterCommit(fn: () => void): void {
    this.afterCommit.push(fn);
  }

  addAfterRollback(fn: () => void): void {
    this.afterRollback.push(fn);
  }

  tx<T>(fn: () => T): T {
    if (this.depth > 0) {
      this.depth++;
      try {
        return fn();
      } finally {
        this.depth--;
      }
    }
    this.raw.exec("BEGIN IMMEDIATE");
    this.depth = 1;
    let result: T;
    try {
      result = fn();
      // Flushers may emit more events; they run inside the transaction.
      for (const hook of this.beforeCommit) hook();
      this.raw.exec("COMMIT");
    } catch (err) {
      this.depth = 0;
      if (this.raw.inTransaction) this.raw.exec("ROLLBACK");
      for (const hook of this.afterRollback) hook();
      throw err;
    }
    this.depth = 0;
    for (const hook of this.afterCommit) hook();
    return result;
  }

  close(): void {
    this.statements.clear();
    this.raw.close();
  }

  migrate(dir: string): void {
    this.raw.exec(
      "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL)",
    );
    const applied = new Set(
      (this.raw.prepare("SELECT version FROM schema_migrations").all() as Array<{ version: number }>).map(
        (r) => r.version,
      ),
    );
    const files = readdirSync(dir)
      .filter((f) => /^\d+_.*\.sql$/.test(f))
      .sort();
    for (const f of files) {
      const version = Number.parseInt(f.split("_")[0]!, 10);
      if (applied.has(version)) continue;
      const sql = readFileSync(path.join(dir, f), "utf8");
      const apply = this.raw.transaction(() => {
        this.raw.exec(sql);
        this.raw
          .prepare("INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)")
          .run(version, f, new Date().toISOString());
      });
      apply();
    }
  }
}

export function openDb(file: string, migrationsDir = srcPath("db", "migrations")): Db {
  const db = new SqliteDb(file);
  db.migrate(migrationsDir);
  return db;
}

// ---- helpers for JSON columns ----

export function toJson(value: unknown): string {
  return JSON.stringify(value);
}

export function fromJson<T>(text: string | null | undefined, fallback: T): T {
  if (text === null || text === undefined || text === "") return fallback;
  return JSON.parse(text) as T;
}
