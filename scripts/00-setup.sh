#!/bin/bash
# One-time setup after `docker compose up -d`:
#   1. build the star schema (dims + fact + history tables)
#   2. seed gold from the day-1 bronze snapshot Debezium lands automatically
#
# Run this once per fresh environment (i.e. after `docker compose down -v`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Step 1: build the star schema ==="
"$SCRIPT_DIR/run-trino.sh" "$REPO_ROOT/lakehouse-sql/01_star_schema.sql"

echo ""
echo "=== Step 2: wait for Debezium's initial snapshot to land in bronze ==="
echo "(the day-1 seed has 3 rows -- waiting up to 60s for them to appear)"
SNAPSHOT_READY=0
for i in $(seq 1 20); do
  COUNT=$(docker exec dl_trino trino --catalog iceberg --schema iam \
    --output-format=CSV_UNQUOTED \
    --execute "SELECT COUNT(*) FROM bronze_dev_iam_public_iam_denormalized" 2>/dev/null || echo "0")
  echo "  bronze row count: $COUNT"
  if [ "$COUNT" -ge 3 ] 2>/dev/null; then
    echo "  bronze snapshot has landed."
    SNAPSHOT_READY=1
    break
  fi
  sleep 3
done

if [ "$SNAPSHOT_READY" -ne 1 ]; then
  echo "FAILED: bronze did not reach 3 rows within 60s." >&2
  echo "Check 'docker logs dl_debezium_server' before proceeding -- running" >&2
  echo "the gold merge now would seed gold from an incomplete snapshot." >&2
  exit 1
fi

echo ""
echo "=== Step 3: seed gold from the day-1 bronze snapshot ==="
"$SCRIPT_DIR/run-trino.sh" "$REPO_ROOT/lakehouse-sql/03_bronze_to_gold.sql"

echo ""
echo "=== Setup complete -- current gold row counts ==="
docker exec dl_trino trino --catalog iceberg --schema iam \
  --execute "SELECT COUNT(*) AS fact_access_grant_rows FROM fact_access_grant"
docker exec dl_trino trino --catalog iceberg --schema iam \
  --execute "SELECT COUNT(*) AS fact_access_grant_history_rows FROM fact_access_grant_history"
