#!/usr/bin/env bash
set -euo pipefail

# 실제 제품의 설정 해석 검증. 환경변수의 업무 값·학교 자원 상태에 대한 단정 제외.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE=(docker compose
  --project-name "omagotchi-observability-config-test-$$"
  --env-file "${INFRA_DIR}/.env.prod.example"
  --file "${INFRA_DIR}/observability/compose.yaml")

cleanup() {
  # 이 테스트에서 만든 프로젝트의 임시 Volume·Network만 정리.
  "${COMPOSE[@]}" down --volumes >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${COMPOSE[@]}" config --quiet
"${COMPOSE[@]}" run --rm --no-deps filebeat \
  filebeat test config --strict.perms=false -e -E logging.level=error \
  -E 'output.elasticsearch.hosts=["http://127.0.0.1:1"]'

# 수집 입력이 없는 초기화 설정의 해석 검증. 실제 setup은 로컬 종단 검증·운영 최초 적용에서 수행.
"${COMPOSE[@]}" run --rm --no-deps --entrypoint filebeat filebeat-setup \
  export config --strict.perms=false -e -E logging.level=error >/dev/null

jq -e . "${INFRA_DIR}/observability/elasticsearch/index-template.json" >/dev/null
jq -e . "${INFRA_DIR}/observability/elasticsearch/lifecycle-policy.json" >/dev/null
echo '관측 Compose·Filebeat 설정 해석 통과. Elasticsearch 쓰기·Telegram 전송 없음.'
