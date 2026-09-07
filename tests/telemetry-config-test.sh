#!/usr/bin/env bash
set -euo pipefail

# 고정 버전 제품의 설정 해석·Alert 수식 검증. 학교 자원 접속·Telegram 전송 없음.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${INFRA_DIR}"

docker compose --env-file .env.prod.example --file observability/compose.yaml \
  --profile metrics config --quiet
jq -e . observability/grafana/dashboards/http-overview.json >/dev/null

# 로컬 Docker 장애 시 동일 버전의 공식 Native Binary로 검증 가능.
if [[ -n "${PROMTOOL_BIN:-}" ]]; then
  "${PROMTOOL_BIN}" check config observability/prometheus/prometheus.yml
  "${PROMTOOL_BIN}" test rules tests/fixtures/prometheus-http-rules.yml
else
  docker run --rm --network none --read-only \
    --mount "type=bind,src=${INFRA_DIR},dst=/workspace,readonly" \
    --workdir /workspace --entrypoint /bin/promtool prom/prometheus:v3.13.2 \
    check config observability/prometheus/prometheus.yml
  # 집계 규칙 평가용 임시 DB 공간만 쓰기 허용, 설정·Fixture는 읽기 전용 유지.
  docker run --rm --network none --read-only --tmpfs /tmp:size=64m,mode=1777 \
    --mount "type=bind,src=${INFRA_DIR},dst=/workspace,readonly" \
    --workdir /workspace --entrypoint /bin/promtool prom/prometheus:v3.13.2 \
    test rules tests/fixtures/prometheus-http-rules.yml
fi

echo '메트릭 설정과 HTTP 오류 집계 검증 통과. Grafana 기동 검증은 별도.'
