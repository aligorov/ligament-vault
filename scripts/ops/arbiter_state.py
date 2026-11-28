"""Persist one arbiter tick atomically in the local control database."""
from pathlib import Path
from contextlib import closing
import sqlite3
import sys


def main():
    db, action, *args = sys.argv[1:]
    with closing(sqlite3.connect(Path(db).resolve().as_uri() + "?mode=rw", uri=True, timeout=8)) as conn, conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS edge_state (
            id INTEGER PRIMARY KEY CHECK (id=1), active TEXT NOT NULL, ip TEXT NOT NULL,
            failures INTEGER NOT NULL, switched INTEGER NOT NULL,
            probe_count INTEGER NOT NULL, last_probe INTEGER NOT NULL)""")
        conn.execute("CREATE TABLE IF NOT EXISTS edge_publication_pending (id INTEGER PRIMARY KEY CHECK(id=1))")
        if action == "read":
            row = conn.execute("SELECT active,ip,failures,switched,probe_count,last_probe FROM edge_state WHERE id=1").fetchone()
            if row:
                pending = conn.execute("SELECT EXISTS(SELECT 1 FROM edge_publication_pending)").fetchone()[0]
                print(*row, pending, sep="|")
        elif action == "pending":
            conn.execute("INSERT OR IGNORE INTO edge_publication_pending VALUES (1)")
        elif action in ("write", "commit"):
            node, ip, *counts = args
            conn.execute("INSERT OR REPLACE INTO edge_state VALUES (1, ?, ?, ?, ?, ?, ?)",
                         (node, ip, *(int(n) for n in counts)))
            if action == "commit":
                conn.execute("DELETE FROM edge_publication_pending")
        else:
            raise ValueError("Неизвестная операция БД арбитра")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, sqlite3.Error) as exc:
        sys.exit(str(exc))
