#!/bin/bash
# Run the acceptance-test business questions, then prove idempotency by
# re-running the bronze-to-gold merge with no new events and confirming
# gold row counts don't change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MERGE_SCRIPT="$REPO_ROOT/lakehouse-sql/03_bronze_to_gold.sql"
ACCEPTANCE_SCRIPT="$REPO_ROOT/lakehouse-sql/04_acceptance_queries.sql"

count_query() {
  docker exec dl_trino trino --catalog iceberg --schema iam \
    --output-format=CSV_UNQUOTED --execute "$1" 2>/dev/null | tail -1
}

echo "=== Acceptance queries (Q1-Q8) ==="
"$SCRIPT_DIR/run-trino.sh" "$ACCEPTANCE_SCRIPT"

echo ""
echo "=== Idempotency check ==="
BEFORE_FACT=$(count_query "SELECT COUNT(*) FROM fact_access_grant")
BEFORE_HIST=$(count_query "SELECT COUNT(*) FROM fact_access_grant_history")
echo "Before re-run: fact_access_grant=$BEFORE_FACT  fact_access_grant_history=$BEFORE_HIST"

echo "Re-running the merge with no new bronze events..."
"$SCRIPT_DIR/run-trino.sh" "$MERGE_SCRIPT"

AFTER_FACT=$(count_query "SELECT COUNT(*) FROM fact_access_grant")
AFTER_HIST=$(count_query "SELECT COUNT(*) FROM fact_access_grant_history")
echo "After re-run:  fact_access_grant=$AFTER_FACT  fact_access_grant_history=$AFTER_HIST"

if [ "$BEFORE_FACT" = "$AFTER_FACT" ] && [ "$BEFORE_HIST" = "$AFTER_HIST" ]; then
  echo "PASS: gold row counts unchanged -- merge is idempotent."
else
  echo "FAIL: gold row counts changed on a re-run with no new events!" >&2
  exit 1
fi

echo ""
echo "=== Duplicate current-version check (must be zero rows) ==="
docker exec dl_trino trino --catalog iceberg --schema iam --execute \
  "SELECT grant_id, COUNT(*) AS current_version_count FROM fact_access_grant_history WHERE is_current GROUP BY grant_id HAVING COUNT(*) > 1"
echo "(no output above this line means zero rows -- correct)"
