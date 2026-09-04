#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NGINX_CONFIG="${INFRA_DIR}/nginx/conf.d/default.conf"

fail() {
  echo "$1" >&2
  exit 1
}

assert_contains() {
  local pattern="$1"
  local message="$2"

  grep -Fq -- "${pattern}" "${NGINX_CONFIG}" || fail "${message}"
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

# 내부 API의 정확한 Root·하위 경로 차단
assert_location_returns_404 "location = /api/v1/internal {"
assert_location_returns_404 "location ^~ /api/v1/internal/ {"

# Docker Container IP의 주기적 재해석
assert_contains "resolver 127.0.0.11 valid=10s ipv6=off;" \
  "Docker Embedded DNS resolver가 누락되었습니다."
assert_contains "zone frontend_upstream 64k;" \
  "Frontend 동적 Upstream Zone이 누락되었습니다."
assert_contains "server frontend:8080 resolve;" \
  "Frontend Upstream의 동적 DNS 재해석이 누락되었습니다."
assert_contains "zone gateway_upstream 64k;" \
  "Gateway 동적 Upstream Zone이 누락되었습니다."
assert_contains "server gateway-service:8080 resolve;" \
  "Gateway Upstream의 동적 DNS 재해석이 누락되었습니다."
assert_contains "proxy_pass http://frontend_upstream;" \
  "Root Route가 동적 Frontend Upstream을 사용하지 않습니다."
assert_contains "proxy_pass http://gateway_upstream;" \
  "API Route가 동적 Gateway Upstream을 사용하지 않습니다."
assert_contains "proxy_pass http://gateway_upstream/actuator/health;" \
  "Gateway Health Route가 동적 Upstream을 사용하지 않습니다."

echo "Nginx routing tests passed"
