#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
TEST_NETWORK="omagotchi-relabel-$$"
METRICS_NAME="omagotchi-metrics-fixture-$$"
PROMETHEUS_NAME="omagotchi-prometheus-relabel-$$"

cleanup() {
  local exit_status=$?
  if ((exit_status != 0)); then
    docker logs --tail 15 "${PROMETHEUS_NAME}" >&2 || true
    docker logs --tail 5 "${METRICS_NAME}" >&2 || true
  fi
  docker rm --force "${PROMETHEUS_NAME}" "${METRICS_NAME}" >/dev/null 2>&1 || true
  docker network rm "${TEST_NETWORK}" >/dev/null 2>&1 || true
  rm -rf -- "${TEST_TMP_DIR}"
}
trap cleanup EXIT

# 외부 접속 없는 임시 Network. 운영 설정은 그대로 사용, Prediction의 응답만 Fixture로 대체.
docker network create --internal "${TEST_NETWORK}" >/dev/null
docker run --detach --name "${METRICS_NAME}" --network "${TEST_NETWORK}" \
  --network-alias prediction-service --read-only --memory 32m --cpus 0.5 \
  --tmpfs /var/cache/nginx:size=8m --tmpfs /var/run:size=1m \
  --mount "type=bind,src=${SCRIPT_DIR}/fixtures/prediction-metrics.conf,dst=/etc/nginx/nginx.conf,readonly" \
  --mount "type=bind,src=${SCRIPT_DIR}/fixtures/prediction-metrics.prom,dst=/fixtures/prediction-metrics.prom,readonly" \
  nginx:1.30.3-alpine >/dev/null
docker run --detach --name "${PROMETHEUS_NAME}" --network "${TEST_NETWORK}" \
  --network-alias prometheus --read-only --memory 192m --cpus 0.5 \
  --tmpfs /prometheus:size=64m,mode=1777 \
  --mount "type=bind,src=${INFRA_DIR}/observability/prometheus,dst=/etc/prometheus,readonly" \
  prom/prometheus:v3.13.2 --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus >/dev/null

# 실제 15초 Scrape 주기를 기다린 뒤 저장된 시계열 조회. 설정 문자열 비교가 아닌 변환 결과 검증.
for _ in {1..60}; do
  if docker exec "${METRICS_NAME}" wget -T 2 -qO- \
    'http://prometheus:9090/api/v1/query?query=%7Bjob%3D%22prediction-service%22%7D' \
    >"${TEST_TMP_DIR}/series.json" 2>/dev/null \
    && jq -e 'any(.data.result[]?; .metric.__name__ == "http_server_requests_seconds_count")' \
      "${TEST_TMP_DIR}/series.json" >/dev/null; then
    break
  fi
  sleep 0.5
done

jq -e '
  .status == "success" and
  (.data.result | map(select(.metric.__name__ | startswith("http_server_requests_seconds_"))) as $http
    | ($http | length) == 6
      and all($http[]; .metric.http_request_method == null and .metric.http_response_status_code == null
        and .metric.http_route == null)
      and ([$http[] | select(.metric.method == "POST" and .metric.status == "200" and .metric.uri == "/predict")] | length) == 3
      and ([$http[] | select(.metric.method == "GET" and .metric.status == "404" and .metric.uri == "UNMATCHED")] | length) == 3)
    and any(.data.result[]; .metric.__name__ == "process_cpu_seconds_total" and .metric.uri == null)
    and all(.data.result[]; .metric.__name__ != "private_business_total")
' "${TEST_TMP_DIR}/series.json" >/dev/null

echo 'Prediction 메트릭 실제 수집 통과: Label 정규화·UNMATCHED·원본 Label 제거·허용 Meter 확인.'
