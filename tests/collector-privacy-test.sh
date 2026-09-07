#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
COLLECTOR_NAME="omagotchi-collector-privacy-$$"
collector_pid=""

cleanup() {
  local exit_status=$?
  if ((exit_status != 0)); then
    if [[ -n "${collector_pid}" ]]; then
      head -n 5 "${TEST_TMP_DIR}/collector.log" >&2
    else
      docker logs --tail 15 "${COLLECTOR_NAME}" >&2 || true
    fi
  fi
  if [[ -n "${collector_pid}" ]]; then
    kill "${collector_pid}" 2>/dev/null || true
    wait "${collector_pid}" 2>/dev/null || true
  elif [[ -z "${OTELCOL_BIN:-}" ]]; then
    docker rm --force "${COLLECTOR_NAME}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${TEST_TMP_DIR}"
}
trap cleanup EXIT

# 같은 HTTP Span의 Link 없는 정상형과 Link 포함 제외형. 가짜 민감정보만 사용.
jq '.resourceSpans[0].scopeSpans[0].spans |=
  [ (.[0] | del(.links)), (.[0] | .spanId = "4444444444444444") ]' \
  "${SCRIPT_DIR}/fixtures/collector-privacy.json" >"${TEST_TMP_DIR}/input.json"

if [[ -n "${OTELCOL_BIN:-}" ]]; then
  test_port="$((20000 + RANDOM % 20000))"
  TEST_OTLP_ENDPOINT="127.0.0.1:${test_port}" TEST_HEALTH_ENDPOINT=127.0.0.1:0 \
    TEST_OUTPUT_PATH="${TEST_TMP_DIR}/traces.json" \
    "${OTELCOL_BIN}" \
    --config "${INFRA_DIR}/observability/otel-collector/config.yaml" \
    --config "${SCRIPT_DIR}/fixtures/collector-file-export.yaml" \
    >"${TEST_TMP_DIR}/collector.log" 2>&1 &
  collector_pid=$!
else
  docker run --detach --name "${COLLECTOR_NAME}" --read-only \
    --user "$(id -u):$(id -g)" --cap-drop ALL --memory 384m --cpus 0.5 \
    --publish 127.0.0.1::4318 \
    --env TEST_OTLP_ENDPOINT=0.0.0.0:4318 --env TEST_HEALTH_ENDPOINT=0.0.0.0:13133 \
    --env TEST_OUTPUT_PATH=/output/traces.json \
    --mount "type=bind,src=${TEST_TMP_DIR},dst=/output" \
    --mount "type=bind,src=${INFRA_DIR}/observability/otel-collector/config.yaml,dst=/config.yaml,readonly" \
    --mount "type=bind,src=${SCRIPT_DIR}/fixtures/collector-file-export.yaml,dst=/test.yaml,readonly" \
    otel/opentelemetry-collector-contrib:0.160.0 \
    --config /config.yaml --config /test.yaml >/dev/null
  test_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4318/tcp") 0).HostPort}}' "${COLLECTOR_NAME}")"
fi

# OTLP Endpoint 준비 확인. 아직 요청 본문을 보내지 않는 상태 조회.
for _ in {1..40}; do
  if [[ -n "${collector_pid}" ]] && ! kill -0 "${collector_pid}" 2>/dev/null; then
    echo 'Collector 기동 실패' >&2
    exit 1
  fi
  if curl --disable --silent --output /dev/null --max-time 1 "http://127.0.0.1:${test_port}/v1/traces"; then
    break
  fi
  sleep 0.1
done
curl --disable --fail --silent --show-error --max-time 5 \
  --header 'Content-Type: application/json' \
  --data-binary "@${TEST_TMP_DIR}/input.json" \
  "http://127.0.0.1:${test_port}/v1/traces" >/dev/null

for _ in {1..40}; do
  [[ ! -s "${TEST_TMP_DIR}/traces.json" ]] || break
  sleep 0.1
done
[[ -s "${TEST_TMP_DIR}/traces.json" ]] || { echo '정제된 Span 출력 누락' >&2; exit 1; }
if grep -Fq PRIVATE_FIXTURE_SECRET "${TEST_TMP_DIR}/traces.json"; then
  echo '정제 후 가짜 비밀값 잔존' >&2
  exit 1
fi
jq -se '
  [.[].resourceSpans[].scopeSpans[].spans[]] as $spans
  | ($spans | length) == 1
    and ($spans[0] | .traceId == "11111111111111111111111111111111"
      and .spanId == "2222222222222222" and .parentSpanId == "3333333333333333"
      and .name == "GET" and .status.code == 2
      and any(.attributes[]; .key == "http.route" and .value.stringValue == "/api/v1/rules/{ruleId}"))
' "${TEST_TMP_DIR}/traces.json" >/dev/null

echo 'Collector 실제 정제 통과: URL·Header·임의 속성·Event 제거, Link 포함 Span 제외, HTTP 부모·자식 관계 보존.'
