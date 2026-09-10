#!/usr/bin/env bash
# 배포 Runner의 SSH 접속 설정. 자동 배포·수동 설정 동기화에서 공동 사용.
set -euo pipefail

: "${DEPLOY_HOST:?DEPLOY_HOST is required}"
: "${DEPLOY_PORT:?DEPLOY_PORT is required}"
: "${DEPLOY_USER:?DEPLOY_USER is required}"
: "${DEPLOY_PATH:?DEPLOY_PATH is required}"
: "${DEPLOY_SSH_KEY:?DEPLOY_SSH_KEY is required}"
: "${DEPLOY_KNOWN_HOSTS:?DEPLOY_KNOWN_HOSTS is required}"

[[ "${DEPLOY_HOST}" =~ ^[A-Za-z0-9.-]+$ ]] || {
  echo "DEPLOY_HOST 형식이 올바르지 않습니다." >&2
  exit 64
}
if [[ ! "${DEPLOY_PORT}" =~ ^[0-9]{1,5}$ ]] ||
  ((10#${DEPLOY_PORT} < 1 || 10#${DEPLOY_PORT} > 65535)); then
  echo "DEPLOY_PORT 형식이 올바르지 않습니다." >&2
  exit 64
fi
[[ "${DEPLOY_USER}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || {
  echo "DEPLOY_USER 형식이 올바르지 않습니다." >&2
  exit 64
}
[[ "${DEPLOY_PATH}" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
  echo "DEPLOY_PATH 형식이 올바르지 않습니다." >&2
  exit 64
}

install -d -m 700 "$HOME/.ssh"

printf '%s\n' "$DEPLOY_SSH_KEY" \
  > "$HOME/.ssh/deploy_key"

printf '%s\n' "$DEPLOY_KNOWN_HOSTS" \
  > "$HOME/.ssh/known_hosts"

chmod 600 "$HOME/.ssh/deploy_key"
chmod 644 "$HOME/.ssh/known_hosts"
