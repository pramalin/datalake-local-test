#!/bin/bash
# Run a SQL file against the Postgres source, via docker exec + psql.
# Usage: scripts/run-postgres.sh path/to/file.sql
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

echo "==> Running $SQLFILE against Postgres (iam_source)"
docker exec -i dl_postgres psql -U iam_user -d iam_source -v ON_ERROR_STOP=1 -f - < "$SQLFILE"
echo "==> Done: $SQLFILE"
