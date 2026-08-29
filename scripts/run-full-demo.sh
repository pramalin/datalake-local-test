#!/bin/bash
# Full hands-off demo run: fresh environment, star schema, full narrative
# replay (merging after every event), then acceptance queries and the
# idempotency proof. Useful for a clean rehearsal before presenting.
#
# WARNING: this runs `docker compose down -v`, which deletes all local
# data volumes. Only run this when you want a genuinely fresh start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Resetting the environment (docker compose down -v && up -d) ==="
cd "$REPO_ROOT"
docker compose down -v
docker compose up -d

echo ""
echo "=== Waiting for Trino to finish initializing ==="
for i in $(seq 1 30); do
  if docker exec dl_trino trino --execute "SELECT 1" >/dev/null 2>&1; then
    echo "Trino is ready."
    break
  fi
  echo "  still initializing... (${i}/30)"
  sleep 3
  if [ "$i" -eq 30 ]; then
    echo "Trino did not become ready in time." >&2
    exit 1
  fi
done

echo ""
echo "=== Running setup ==="
"$SCRIPT_DIR/00-setup.sh"

echo ""
echo "=== Replaying the narrative ==="
"$SCRIPT_DIR/01-replay-narrative.sh"

echo ""
echo "=== Verifying ==="
"$SCRIPT_DIR/02-verify.sh"

echo ""
echo "=== Full demo run complete ==="
