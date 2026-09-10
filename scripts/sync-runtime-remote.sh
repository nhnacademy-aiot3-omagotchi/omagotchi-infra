#!/usr/bin/env bash
# 배포 Runner의 후보 설정 전달과 서버 동기화 호출. 운영 값 출력 제외.
set -euo pipefail
umask 077

: "${PROD_ENV:?PROD_ENV is required}"

runner_env_file="${RUNNER_TEMP}/prod.env"
incoming_name=".incoming-prod.env.${GITHUB_RUN_ID}.${GITHUB_RUN_ATTEMPT}"
incoming_path="${DEPLOY_PATH%/}/../secrets/${incoming_name}"

cleanup() {
  rm -f -- "${runner_env_file}"
  ssh \
    -i "$HOME/.ssh/deploy_key" \
    -p "$DEPLOY_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 \
    "$DEPLOY_USER@$DEPLOY_HOST" \
    "rm -f -- '${incoming_path}'" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%s\n' "$PROD_ENV" >"${runner_env_file}"
unset PROD_ENV
chmod 600 "${runner_env_file}"

scp \
  -i "$HOME/.ssh/deploy_key" \
  -P "$DEPLOY_PORT" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=10 \
  "${runner_env_file}" \
  "$DEPLOY_USER@$DEPLOY_HOST:${incoming_path}"

ssh \
  -i "$HOME/.ssh/deploy_key" \
  -p "$DEPLOY_PORT" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=10 \
  "$DEPLOY_USER@$DEPLOY_HOST" \
  "bash -s -- '$DEPLOY_PATH' '$GITHUB_SHA' '$incoming_path'" \
  < scripts/sync-runtime-config.sh
