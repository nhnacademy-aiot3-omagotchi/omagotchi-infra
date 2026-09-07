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

# 운영 Compose의 옵션으로 실행. 옵션 누락 시에도 정제 검증이 통과하는 상황 방지.
collector_feature_gates="$(docker compose --env-file "${INFRA_DIR}/.env.prod.example" \
  --file "${INFRA_DIR}/observability/compose.yaml" --profile tracing config --format json \
  | jq -r '.services["otel-collector"].command[] | select(startswith("--feature-gates=")) | ltrimstr("--feature-gates=")')"

if [[ -n "${OTELCOL_BIN:-}" ]]; then
  test_port="$((20000 + RANDOM % 20000))"
  TEST_OTLP_ENDPOINT="127.0.0.1:${test_port}" TEST_HEALTH_ENDPOINT=127.0.0.1:0 \
    TEST_OUTPUT_PATH="${TEST_TMP_DIR}/traces.json" \
    "${OTELCOL_BIN}" \
    --feature-gates="${collector_feature_gates}" \
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
    --config /config.yaml --config /test.yaml --feature-gates="${collector_feature_gates}" >/dev/null
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
  --data-binary "@${SCRIPT_DIR}/fixtures/collector-privacy.json" \
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
# 입력의 종류·시간·부모 관계와 출력의 일치 확인. Span 종류에 따른 삭제·HTTP 이름 덮어쓰기 방지.
jq -se --slurpfile input "${SCRIPT_DIR}/fixtures/collector-privacy.json" '
  [.[].resourceSpans[].scopeSpans[].spans[]] | sort_by(.spanId) as $spans
  | [$input[0].resourceSpans[].scopeSpans[].spans[]] | sort_by(.spanId) as $original
  | ($spans | map({traceId, spanId, parentSpanId, kind, startTimeUnixNano, endTimeUnixNano}))
      == ($original | map({traceId, spanId, parentSpanId, kind, startTimeUnixNano, endTimeUnixNano}))
    and ($spans | map(.name)) == ["GET", "Internal", "DB", "Redis", "AI", "AI tool", "Messaging", "prediction.inference", "GET", "POST", "GET"]
    and all($spans[]; ((.events // []) | length) == 0 and ((.links // []) | length) == 0
      and (.traceState // "") == "" and (.status.message // "") == "")
    and ($spans[0] | .status.code == 2
      and any(.attributes[]; .key == "http.route" and .value.stringValue == "/api/v1/rules/{ruleId}"))
    and ($spans[2] | any(.attributes[]; .key == "db.query.summary" and .value.stringValue == "SELECT study_records"))
    and ($spans[3] | any(.attributes[]; .key == "db.operation" and .value.stringValue == "GET"))
    and ($spans[4] | any(.attributes[]; .key == "gen_ai.usage.input_tokens" and (.value.intValue | tonumber) == 20))
    and ($spans[5] | any(.attributes[]; .key == "spring.ai.tool.definition.name" and .value.stringValue == "lookupStudySummary"))
    and ($spans[6] | any(.attributes[]; .key == "messaging.operation.type" and .value.stringValue == "process"))
' "${TEST_TMP_DIR}/traces.json" >/dev/null

# Spring 서버·클라이언트 속성 변환과 응답 없는 호출의 보존 확인.
jq -se '
  [.[].resourceSpans[].scopeSpans[].spans[]] | INDEX(.spanId) as $spans
  | ($spans["cccccccccccccccc"].attributes | from_entries) as $server
  | ($spans["dddddddddddddddd"].attributes | from_entries) as $client
  | ($spans["eeeeeeeeeeeeeeee"].attributes | from_entries) as $failure
  | $server["http.request.method"].stringValue == "GET"
    and ($server["http.response.status_code"].intValue | tonumber) == 200
    and $server["http.route"].stringValue == "/api/v1/rules/{ruleId}"
    and $server["error.type"] == null
    and $client["http.request.method"].stringValue == "POST"
    and ($client["http.response.status_code"].intValue | tonumber) == 200
    and $client["server.address"].stringValue == "example.invalid"
    and $client["http.route"] == null and $client["uri"] == null
    and $failure["error.type"].stringValue == "IOException"
    and $failure["http.response.status_code"] == null
    and $spans["eeeeeeeeeeeeeeee"].status.code == 2
' "${TEST_TMP_DIR}/traces.json" >/dev/null

jq -se 'all(.[].resourceSpans[].scopeSpans[]; (.scope.name // "") == "" and (.scope.version // "") == "")' \
  "${TEST_TMP_DIR}/traces.json" >/dev/null

echo 'Collector 실제 정제 통과: 주요 Span·부모 관계 보존, Scope 식별자·원문·Event·Link 제거.'
