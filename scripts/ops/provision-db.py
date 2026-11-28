"""Runs inside the writable Patroni container. Credentials arrive via SSH and stdin."""
import json
import sys

import psycopg2
from psycopg2 import sql


def main():
    passwords = json.load(sys.stdin)
    conn = psycopg2.connect(dbname="postgres", user="postgres", host="/var/run/postgresql", port=sys.argv[1])
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("SELECT pg_is_in_recovery()")
        if cur.fetchone()[0]:
            return 2
        for role, database in (("sftpgo", "sftpgo"), ("seaweedfs", "seaweedfs_filer"), ("client_logger", None)):
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (role,))
            operation = "ALTER ROLE" if cur.fetchone() else "CREATE ROLE"
            cur.execute(sql.SQL(operation + " {} LOGIN PASSWORD %s").format(sql.Identifier(role)), (passwords[role],))
            if database:
                cur.execute("SELECT 1 FROM pg_database WHERE datname=%s", (database,))
                if not cur.fetchone():
                    cur.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(sql.Identifier(database), sql.Identifier(role)))
        cur.execute("""CREATE TABLE IF NOT EXISTS public.client_events(
            event_id text PRIMARY KEY, node text NOT NULL, received_at timestamptz NOT NULL DEFAULT now(),
            event jsonb NOT NULL)""")
        cur.execute("GRANT INSERT ON public.client_events TO client_logger")
    conn.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (psycopg2.OperationalError, psycopg2.errors.ReadOnlySqlTransaction):
        sys.exit(2)
