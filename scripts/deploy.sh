#!/usr/bin/env bash
# deploy.sh — pull all repos and restart the stack.
# Run directly or invoked via GitHub Actions SSH step.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECTS_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"

echo "==> Pulling latest code..."
git -C "$PROJECTS_DIR/callsheet-api"    pull
git -C "$PROJECTS_DIR/callsheet-ui"     pull
git -C "$PROJECTS_DIR/callsheet-deploy" pull

echo "==> Rebuilding and restarting containers..."
cd "$DEPLOY_DIR"
docker compose up --build -d --remove-orphans

echo "==> Done."
docker compose ps
