#!/usr/bin/env bash
set -euo pipefail

# 고정 버전 제품의 설정 해석·Alert 수식 검증. 학교 자원 접속·Telegram 전송 없음.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${INFRA_DIR}"

docker compose --env-file .env.prod.example --file observability/compose.yaml \
  --profile metrics --profile tracing config --quiet
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

if [[ -n "${OTELCOL_BIN:-}" ]]; then
  "${OTELCOL_BIN}" validate --config observability/otel-collector/config.yaml
else
  docker run --rm --network none --read-only \
    --mount "type=bind,src=${INFRA_DIR}/observability/otel-collector/config.yaml,dst=/config.yaml,readonly" \
    otel/opentelemetry-collector-contrib:0.160.0 validate --config /config.yaml
fi

# 운영 Compose와 같은 단일 프로세스 설정 검사. 실제 기동·저장 검증은 별도.
docker run --rm --network none --read-only \
  --mount "type=bind,src=${INFRA_DIR}/observability/tempo/config.yaml,dst=/config.yaml,readonly" \
  grafana/tempo:3.0.3 -target=all -config.file=/config.yaml -config.verify=true

echo '메트릭·트레이스 설정과 HTTP 오류 집계 검증 통과. Tempo·Grafana 기동 검증은 별도.'
