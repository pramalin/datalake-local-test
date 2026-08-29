#!/bin/bash
# Assert specific, correct business answers -- not just "the query ran."
# This directly addresses external review feedback: row-count stability
# on a no-op re-run (scripts/02-verify.sh) proves idempotency, but says
# nothing about whether the ANSWERS are correct. This script checks the
# answers.
#
# One honest limitation, stated up front rather than hidden: this does
# NOT assert "the contractor has no access after March 1" (the exact
# narrative delete date), because the current implementation cannot
# guarantee that -- hard deletes close using Debezium's CAPTURE time
# (whenever you actually run the demo), not the narrative's March 1
# label, since Postgres never sends a business-level "deleted at"
# timestamp for a hard delete. Asserting the narrative date here would
# pass by coincidence today and fail later. See README.md "Known
# limitations" and TROUBLESHOOTING.md issue #17.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILURES=0

run_scalar() {
  # Runs a single-value query and returns the raw result.
  docker exec dl_trino trino --catalog iceberg --schema iam \
    --output-format=CSV_UNQUOTED --execute "$1" 2>/dev/null | tail -1
}

assert_equals() {
  local NAME="$1" QUERY="$2" EXPECTED="$3"
  local ACTUAL
  ACTUAL=$(run_scalar "$QUERY")
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo "PASS: $NAME (expected=$EXPECTED actual=$ACTUAL)"
  else
    echo "FAIL: $NAME (expected=$EXPECTED actual=$ACTUAL)" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

echo "=== Business-answer assertions ==="

assert_equals \
  "Alice has exactly one active grant as of Jan 31" \
  "SELECT COUNT(*) FROM fact_access_grant_history WHERE user_id = 101 AND effective_start <= TIMESTAMP '2026-01-31 23:59:00' AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-01-31 23:59:00')" \
  "1"

assert_equals \
  "Carla has NO active access as of March 1 (revocation regression test)" \
  "SELECT COUNT(*) FROM fact_access_grant_history WHERE user_id = 103 AND resource_id = 503 AND effective_start <= TIMESTAMP '2026-03-01 00:00:00' AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-03-01 00:00:00')" \
  "0"

assert_equals \
  "Contractor had access on Feb 20" \
  "SELECT COUNT(*) FROM fact_access_grant_history WHERE user_id = 104 AND effective_start <= TIMESTAMP '2026-02-20 00:00:00' AND (effective_end IS NULL OR effective_end > TIMESTAMP '2026-02-20 00:00:00')" \
  "1"

assert_equals \
  "Contractor's closed grant is correctly classified as a hard delete (is_deleted=true)" \
  "SELECT COUNT(*) FROM fact_access_grant_history WHERE user_id = 104 AND is_deleted = true AND is_current = false" \
  "1"

assert_equals \
  "No grant has more than one current history version" \
  "SELECT COUNT(*) FROM (SELECT grant_id FROM fact_access_grant_history WHERE is_current GROUP BY grant_id HAVING COUNT(*) > 1)" \
  "0"

assert_equals \
  "Total history row count matches THIS DEMO SCENARIO (6: one row per grant, no phantom rows from revocations/deletes -- scenario-specific, not a generic pipeline invariant)" \
  "SELECT COUNT(*) FROM fact_access_grant_history" \
  "6"

assert_equals \
  "Emma (new hire) currently has active access" \
  "SELECT COUNT(*) FROM fact_access_grant_history WHERE user_id = 105 AND is_current = true" \
  "1"

assert_equals \
  "Bob (never touched) currently has active access" \
  "SELECT COUNT(*) FROM fact_access_grant_history WHERE user_id = 102 AND is_current = true" \
  "1"

assert_equals \
  "current_active_access view returns exactly 3 active grants (Bob, Alice's Auditor grant, Emma)" \
  "SELECT COUNT(*) FROM current_active_access" \
  "3"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL ASSERTIONS PASSED"
  exit 0
else
  echo "$FAILURES ASSERTION(S) FAILED" >&2
  exit 1
fi
