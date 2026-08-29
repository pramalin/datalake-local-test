#!/bin/bash
# Replay the demo narrative, ONE EVENT AT A TIME, merging gold after
# each one. This is deliberate, not just for pacing: the bronze-to-gold
# merge dedups to the LATEST event per grant_id within a single run
# (that's what makes it idempotent). If the whole narrative were applied
# to Postgres first and merged only once at the end, grant_id 5's
# "create" event (Feb 15) would be silently collapsed into its "delete"
# event (Mar 1) by that dedup, and it would never appear in history at
# all. Merging after every event avoids this.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVENTS_DIR="$REPO_ROOT/demo_events"
MERGE_SCRIPT="$REPO_ROOT/lakehouse-sql/03_bronze_to_gold.sql"

# Seconds to wait after each Postgres change for Debezium to capture and
# commit it to bronze before running the merge. 8s has been reliable in
# testing; increase if your machine/network is slower.
WAIT_SECONDS="${WAIT_SECONDS:-8}"

if [ ! -d "$EVENTS_DIR" ]; then
  echo "Events directory not found: $EVENTS_DIR" >&2
  exit 1
fi

for EVENT_FILE in "$EVENTS_DIR"/*.sql; do
  EVENT_NAME=$(basename "$EVENT_FILE")
  echo ""
  echo "############################################################"
  echo "# Event: $EVENT_NAME"
  echo "############################################################"

  "$SCRIPT_DIR/run-postgres.sh" "$EVENT_FILE"

  echo "  waiting ${WAIT_SECONDS}s for Debezium to capture and commit to bronze..."
  sleep "$WAIT_SECONDS"

  "$SCRIPT_DIR/run-trino.sh" "$MERGE_SCRIPT"

  echo "  -- current gold state after $EVENT_NAME --"
  docker exec dl_trino trino --catalog iceberg --schema iam \
    --execute "SELECT COUNT(*) AS fact_access_grant_rows FROM fact_access_grant"
  docker exec dl_trino trino --catalog iceberg --schema iam \
    --execute "SELECT COUNT(*) AS fact_access_grant_history_rows FROM fact_access_grant_history"
done

echo ""
echo "=== Narrative replay complete ==="
echo "Run scripts/02-verify.sh to check the acceptance queries and idempotency."
