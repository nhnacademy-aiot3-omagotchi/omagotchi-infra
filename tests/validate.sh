#!/usr/bin/env bash
set -Eeuo pipefail

# 로컬·PR·main에서 함께 사용하는 검증 진입점. 운영 접속·배포 제외.
INFRA_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${INFRA_DIR}"

echo 'Shell 문법·정적 검사'
for script in scripts/*.sh tests/*.sh; do
  bash -n "${script}"
done
shellcheck scripts/*.sh tests/*.sh

echo 'Compose·Nginx 설정 검사'
docker compose --profile rollout --env-file .env.prod.example --env-file deploy.env.example config --quiet
docker run --rm \
  --mount "type=bind,src=${INFRA_DIR}/nginx/conf.d/default.conf,dst=/etc/nginx/conf.d/default.conf,readonly" \
  --mount "type=bind,src=${INFRA_DIR}/nginx/upstreams.example.conf,dst=/etc/nginx/conf.d/runtime/upstreams.conf,readonly" \
  nginx:1.30.3-alpine nginx -t

for test_script in tests/*-test.sh; do
  printf '\n실행: %s\n' "${test_script}"
  bash "${test_script}"
done
