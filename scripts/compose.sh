#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

exec docker compose \
  --env-file ./deploy.env \
  --env-file ../secrets/prod.env \
  "$@"
