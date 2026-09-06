#!/usr/bin/env bash
set -euo pipefail

# 제품 Runtime의 Rule 해석·전송 경계 검증. 실제 ES·Telegram 접속 없음.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
docker run --rm --network none --read-only --memory 256m --cpus 0.5 \
  --entrypoint python \
  -e PYTHONDONTWRITEBYTECODE=1 -e PYTHONPATH=/opt/elastalert/omagotchi \
  --mount "type=bind,src=${INFRA_DIR}/observability/elastalert2,dst=/opt/elastalert/omagotchi,readonly" \
  --mount "type=bind,src=${INFRA_DIR}/tests/elastalert_test.py,dst=/opt/elastalert/elastalert_test.py,readonly" \
  jertel/elastalert2:2.31.0 -m unittest -v elastalert_test
