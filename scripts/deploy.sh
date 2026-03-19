#!/usr/bin/env bash
# deploy.sh — pull all repos and restart the stack.
# Run directly or invoked via GitHub Actions SSH step.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECTS_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

echo "==> Pulling latest deploy config..."
git -C "$DEPLOY_DIR" fetch origin
git -C "$DEPLOY_DIR" reset --hard origin/HEAD

echo "==> Pulling latest images..."
cd "$DEPLOY_DIR"
docker compose pull

echo "==> Restarting containers..."
docker compose up -d --remove-orphans

echo "==> Done."
docker compose ps

echo "==> Health check..."
sleep 5
UNHEALTHY=$(docker compose ps --format json | python3 -c "
import sys, json
procs = [json.loads(l) for l in sys.stdin if l.strip()]
bad = [p['Name'] for p in procs if p['State'] != 'running']
print('\n'.join(bad))
")
if [ -n "$UNHEALTHY" ]; then
  echo "ERROR: the following containers are not running:"
  echo "$UNHEALTHY"
  exit 1
fi
echo "All containers healthy."
