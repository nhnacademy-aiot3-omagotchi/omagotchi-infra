#!/usr/bin/env bash
set -euo pipefail

"$(dirname "$0")/compose.sh" up -d "$@"
