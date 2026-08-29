#!/bin/bash
# Run a SQL file against Trino (iceberg catalog, iam schema), via
# docker exec + the Trino CLI. Non-interactive: reads the whole file as
# piped stdin, same reliable batch-execution mode psql uses -- avoids the
# DBeaver "Execute Script partially stops" issue seen earlier in this
# project (see TROUBLESHOOTING.md #3).
# Usage: scripts/run-trino.sh path/to/file.sql
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <sql-file>" >&2
  exit 1
fi

SQLFILE="$1"

if [ ! -f "$SQLFILE" ]; then
  echo "File not found: $SQLFILE" >&2
  exit 1
fi

# Defensive: Trino's container can report "Started" well before its
# coordinator actually accepts queries ("Trino server is still
# initializing"). Wait for real readiness before running the file.
for i in $(seq 1 30); do
  if docker exec dl_trino trino --execute "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Trino did not become ready in time." >&2
    exit 1
  fi
  sleep 3
done

echo "==> Running $SQLFILE against Trino (iceberg.iam)"
docker exec -i dl_trino trino --catalog iceberg --schema iam < "$SQLFILE"
echo "==> Done: $SQLFILE"
