"""Spool structured SFTPGo events and deliver them transactionally to PostgreSQL."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
import uuid


SENDERS = {"login", "connection_failed", "Upload", "Download", "Rename", "Remove",
           "Mkdir", "Rmdir", "Symlink", "Chmod", "Chown", "Chtimes", "Copy"}
FIELDS = ("time", "sender", "username", "protocol", "connection_id", "ip", "client_ip",
          "remote_addr", "method", "login_type", "virtual_path", "virtual_target_path",
          "size_bytes", "elapsed_ms", "encrypted")


def ingest(db, directory):
    # Rotation renames files in-place. A random generation ID distinguishes reused inodes.
    for path in sorted(directory.glob("events*.log")):
        try:
            fp = path.open("rb")
        except FileNotFoundError:
            continue
        with fp:
            st = os.fstat(fp.fileno())
            first = fp.readline()
            if not first.endswith(b"\n"):
                continue
            ident = f"{st.st_dev}:{st.st_ino}:{hashlib.sha256(first).hexdigest()}"
            row = db.execute("SELECT generation,pos FROM cursors WHERE file=?", (ident,)).fetchone()
            generation, pos = row if row and row[1] <= st.st_size else (str(uuid.uuid4()), 0)
            fp.seek(pos)
            with db:
                for _ in range(4000):
                    start = fp.tell()
                    raw = fp.readline()
                    if not raw.endswith(b"\n"):
                        break
                    pos = fp.tell()
                    try:
                        data = json.loads(raw)
                    except (ValueError, UnicodeDecodeError):
                        continue
                    if not isinstance(data, dict) or data.get("sender") not in SENDERS:
                        continue
                    event = {k: data[k] for k in FIELDS if k in data}
                    event["failed"] = bool(data.get("error")) or data["sender"] == "connection_failed"
                    key = f"{generation}:{start}"
                    db.execute("INSERT OR IGNORE INTO pending VALUES (?,?)", (key, json.dumps(event)))
                db.execute("INSERT OR REPLACE INTO cursors VALUES (?,?,?)", (ident, generation, pos))


def deliver(db, config):
    rows = db.execute("SELECT id,event FROM pending ORDER BY rowid LIMIT 500").fetchall()
    if not rows:
        return
    import psycopg2
    from psycopg2.extras import Json, execute_values

    conn = psycopg2.connect(**config["postgres"])
    try:
        with conn, conn.cursor() as cur:
            execute_values(cur, "INSERT INTO public.client_events(event_id,node,event) VALUES %s "
                           "ON CONFLICT DO NOTHING", [(k, config["node"], Json(json.loads(v))) for k,v in rows])
    finally:
        conn.close()
    with db:
        db.executemany("DELETE FROM pending WHERE id=?", [(k,) for k,_ in rows])


def main():
    import psycopg2

    os.umask(0o077)
    config = json.loads(Path(sys.argv[1]).read_text())
    with sqlite3.connect("/spool/events.sqlite3") as db:
        db.execute("CREATE TABLE IF NOT EXISTS cursors(file TEXT PRIMARY KEY,generation TEXT,pos INTEGER)")
        db.execute("CREATE TABLE IF NOT EXISTS pending(id TEXT PRIMARY KEY,event TEXT NOT NULL)")
        while True:
            ingest(db, Path("/logs"))
            try:
                deliver(db, config)
            except psycopg2.Error as e:
                print(f"Delivery deferred ({type(e).__name__})", file=sys.stderr, flush=True)
                time.sleep(4)
            time.sleep(1)


if __name__ == "__main__":
    main()
