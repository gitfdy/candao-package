import { DatabaseSync } from 'node:sqlite';

export function openStore(path) {
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS memos (
      id TEXT PRIMARY KEY, owner TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL,
      revision INTEGER NOT NULL, updated TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS memos_owner ON memos(owner);
    CREATE TABLE IF NOT EXISTS notes (
      project TEXT NOT NULL, branch TEXT NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL,
      actor TEXT NOT NULL, updated TEXT NOT NULL, PRIMARY KEY(project, branch));
    CREATE TABLE IF NOT EXISTS builds (
      id INTEGER PRIMARY KEY, request_id TEXT UNIQUE NOT NULL, project TEXT NOT NULL,
      actor TEXT NOT NULL, created TEXT NOT NULL, payload TEXT NOT NULL, job TEXT NOT NULL,
      status TEXT NOT NULL, queue_id INTEGER, number INTEGER, result TEXT, error TEXT);
    CREATE TABLE IF NOT EXISTS audit (
      id INTEGER PRIMARY KEY, actor TEXT NOT NULL, action TEXT NOT NULL, detail TEXT NOT NULL, created TEXT NOT NULL);`);
  const audit = (actor, action, detail) => db.prepare('INSERT INTO audit(actor, action, detail, created) VALUES(?,?,?,?)').run(actor, action, JSON.stringify(detail), new Date().toISOString());
  return { db, audit, close: () => db.close() };
}
