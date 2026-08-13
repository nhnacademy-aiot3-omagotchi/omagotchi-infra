#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NGINX_CONFIG="${INFRA_DIR}/nginx/conf.d/default.conf"

fail() {
  echo "$1" >&2
  exit 1
}

assert_location_returns_404() {
  local location_directive="$1"

  awk -v location_directive="${location_directive}" '
    index($0, location_directive) {
      in_location = 1
      location_found = 1
      next
    }

    in_location && /^[[:space:]]*return 404;[[:space:]]*$/ {
      return_found = 1
    }

    in_location && /^[[:space:]]*}[[:space:]]*$/ {
      exit !(location_found && return_found)
    }

    END {
      if (!location_found || !return_found) {
        exit 1
      }
    }
  ' "${NGINX_CONFIG}" ||
    fail "Nginx 경로가 404로 차단되지 않았습니다: ${location_directive}"
}

# 정확한 루트와 하위 경로를 모두 차단해야 내부 API가 Gateway 인증 단계에 도달하지 않음.
assert_location_returns_404 "location = /api/v1/internal {"
assert_location_returns_404 "location ^~ /api/v1/internal/ {"

echo "Nginx routing tests passed"
