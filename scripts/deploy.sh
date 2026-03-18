#!/usr/bin/env bash
# deploy.sh — pull all repos and restart the stack.
# Run directly or invoked via GitHub Actions SSH step.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECTS_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

echo "==> Pulling latest code..."
for repo in callsheet-api callsheet-ui callsheet-deploy; do
  git -C "$PROJECTS_DIR/$repo" fetch origin
  git -C "$PROJECTS_DIR/$repo" reset --hard origin/HEAD
done

echo "==> Rebuilding and restarting containers..."
cd "$DEPLOY_DIR"
docker compose build --no-cache
docker compose up -d --remove-orphans

echo "==> Done."
docker compose ps
