#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
docker compose --env-file ../secrets/prod.env logs -f "$@"
