#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq 식은 Shell 확장 없이 그대로 전달
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NGINX_CONFIG="${INFRA_DIR}/nginx/conf.d/default.conf"
UPSTREAM_CONFIG="${SCRIPT_DIR}/fixtures/nginx-request-id-upstream.conf"
NGINX_IMAGE="nginx:1.30.3-alpine"
TEST_SUFFIX="$$"
NETWORK_NAME="omagotchi-nginx-test-${TEST_SUFFIX}"
UPSTREAM_NAME="omagotchi-nginx-upstream-${TEST_SUFFIX}"
PROXY_NAME="omagotchi-nginx-proxy-${TEST_SUFFIX}"
TEMP_DIR="$(mktemp -d)"
SENSITIVE_VALUE="sensitive-${TEST_SUFFIX}"
SPOOFED_REQUEST_ID="spoofed-request-id-${TEST_SUFFIX}"

cleanup() {
  docker rm -f "${PROXY_NAME}" "${UPSTREAM_NAME}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
  rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

header_value() {
  local header_name="$1"
  local header_file="$2"

  awk -v header_name="${header_name}" '
    tolower($1) == tolower(header_name ":") {
      sub("\r$", "", $2)
      print $2
    }
  ' "${header_file}"
}

status_code() {
  awk '/^HTTP\// { status = $2 } END { print status }' "$1"
}

response_request_id() {
  local case_name="$1"
  local header_file="$2"
  local request_id

  request_id="$(header_value "X-Request-ID" "${header_file}")"
  [[ "${request_id}" =~ ^[0-9a-f]{32}$ ]] ||
    fail "${case_name}: X-Request-ID가 소문자 32자리 16진수가 아닙니다."
  [[ "$(wc -l <<<"${request_id}" | tr -d ' ')" == "1" ]] ||
    fail "${case_name}: X-Request-ID 응답 Header가 하나가 아닙니다."

  printf '%s' "${request_id}"
}

wait_until_ready() {
  local port="$1"

  for _ in {1..30}; do
    if curl --silent --show-error --fail "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return
    fi
    sleep 0.2
  done

  fail "Nginx 테스트 Container가 준비되지 않았습니다."
}

docker network create "${NETWORK_NAME}" >/dev/null
docker run --detach --rm \
  --name "${UPSTREAM_NAME}" \
  --network "${NETWORK_NAME}" \
  --network-alias frontend \
  --network-alias gateway-service \
  --mount "type=bind,src=${UPSTREAM_CONFIG},dst=/etc/nginx/nginx.conf,readonly" \
  "${NGINX_IMAGE}" >/dev/null

docker run --detach --rm \
  --name "${PROXY_NAME}" \
  --network "${NETWORK_NAME}" \
  --publish "127.0.0.1::80" \
  --tmpfs /var/log/nginx:size=10m,mode=0700 \
  --mount "type=bind,src=${NGINX_CONFIG},dst=/etc/nginx/conf.d/default.conf,readonly" \
  "${NGINX_IMAGE}" >/dev/null

PROXY_PORT="$(
  docker inspect --format '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' \
    "${PROXY_NAME}"
)"
wait_until_ready "${PROXY_PORT}"

API_HEADERS="${TEMP_DIR}/api-headers"
curl --silent --show-error \
  --dump-header "${API_HEADERS}" \
  --output /dev/null \
  --header "X-Request-ID: ${SPOOFED_REQUEST_ID}" \
  --header "Authorization: Bearer ${SENSITIVE_VALUE}" \
  --data "${SENSITIVE_VALUE}" \
  "http://127.0.0.1:${PROXY_PORT}/api/v1/rules/${SENSITIVE_VALUE}?secret=${SENSITIVE_VALUE}"

API_REQUEST_ID="$(response_request_id "API 요청" "${API_HEADERS}")"
[[ "${API_REQUEST_ID}" != "${SPOOFED_REQUEST_ID}" ]] ||
  fail "외부 Request ID가 Nginx 경계에서 교체되지 않았습니다."
[[ "$(header_value "X-Received-Request-ID" "${API_HEADERS}")" == "${API_REQUEST_ID}" ]] ||
  fail "Gateway 전달값과 응답 Request ID가 일치하지 않습니다."

INTERNAL_HEADERS="${TEMP_DIR}/internal-headers"
INTERNAL_BODY="${TEMP_DIR}/internal-body"
curl --silent --show-error \
  --dump-header "${INTERNAL_HEADERS}" \
  --output "${INTERNAL_BODY}" \
  "http://127.0.0.1:${PROXY_PORT}/api/v1/internal/${SENSITIVE_VALUE}"

INTERNAL_REQUEST_ID="$(response_request_id "내부 API 차단" "${INTERNAL_HEADERS}")"
[[ "$(status_code "${INTERNAL_HEADERS}")" == "404" ]] ||
  fail "내부 API가 404로 차단되지 않았습니다."
jq -e --arg request_id "${INTERNAL_REQUEST_ID}" '
  .code == "COMMON_NOT_FOUND"
  and .path == "/api/v1/internal/**"
  and .requestId == $request_id
' "${INTERNAL_BODY}" >/dev/null || fail "내부 API 오류 응답 계약이 일치하지 않습니다."

FAILURE_HEADERS="${TEMP_DIR}/failure-headers"
FAILURE_BODY="${TEMP_DIR}/failure-body"
curl --silent --show-error \
  --dump-header "${FAILURE_HEADERS}" \
  --output "${FAILURE_BODY}" \
  "http://127.0.0.1:${PROXY_PORT}/api/v1/rules/failure/${SENSITIVE_VALUE}"

FAILURE_REQUEST_ID="$(response_request_id "Nginx Upstream 실패" "${FAILURE_HEADERS}")"
[[ "$(status_code "${FAILURE_HEADERS}")" == "502" ]] ||
  fail "Nginx Upstream 실패가 502로 변환되지 않았습니다."
jq -e --arg request_id "${FAILURE_REQUEST_ID}" '
  .code == "COMMON_BAD_GATEWAY"
  and .path == "/api/**"
  and .requestId == $request_id
' "${FAILURE_BODY}" >/dev/null || fail "Nginx Upstream 오류 응답 계약이 일치하지 않습니다."

DOWNSTREAM_HEADERS="${TEMP_DIR}/downstream-headers"
DOWNSTREAM_BODY="${TEMP_DIR}/downstream-body"
curl --silent --show-error \
  --dump-header "${DOWNSTREAM_HEADERS}" \
  --output "${DOWNSTREAM_BODY}" \
  "http://127.0.0.1:${PROXY_PORT}/api/v1/rules/downstream-error"

DOWNSTREAM_REQUEST_ID="$(response_request_id "Downstream 오류" "${DOWNSTREAM_HEADERS}")"
[[ "$(status_code "${DOWNSTREAM_HEADERS}")" == "503" ]] ||
  fail "Downstream 오류 상태가 Nginx에서 변경되었습니다."
[[ "${DOWNSTREAM_REQUEST_ID}" != "downstream-request-id" ]] ||
  fail "Downstream 응답 Header가 Nginx Request ID를 덮어썼습니다."
jq -e '. == {"source":"downstream","status":503}' "${DOWNSTREAM_BODY}" >/dev/null ||
  fail "Downstream 오류 본문이 Nginx에서 변경되었습니다."

docker exec "${PROXY_NAME}" \
  grep -Fq "upstream prematurely closed connection" /var/log/nginx/error.log ||
  fail "Nginx 로컬 오류 로그에 Upstream 실패 원인이 없습니다."

LOG_FILE="${TEMP_DIR}/proxy.log"
EVENT_FILE="${TEMP_DIR}/access-events.jsonl"
docker logs "${PROXY_NAME}" >"${LOG_FILE}" 2>&1
grep -E '^[[:space:]]*\{' "${LOG_FILE}" >"${EVENT_FILE}"

grep -Fq "${SENSITIVE_VALUE}" "${LOG_FILE}" &&
  fail "Nginx stdout 로그에 민감정보가 포함되었습니다."

jq -s -e --arg request_id "${API_REQUEST_ID}" '
  [.[] | select(
    .event.dataset == "nginx.access"
    and .http.request.id == $request_id
  )] as $events
  | ($events | length) == 1
    and ($events[0].service.name == "nginx")
    and ($events[0].event.action == "http.server.request.completed")
    and ($events[0].event.outcome == "success")
    and ($events[0].http.request.method == "POST")
    and ($events[0].http.response.status_code == 204)
    and ($events[0].omagotchi.http.route == "/api/**")
    and ($events[0].nginx.request_time_seconds | type == "number")
    and (($events[0] | has("url")) | not)
' "${EVENT_FILE}" >/dev/null || fail "Nginx 접근 이벤트의 필수 계약이 일치하지 않습니다."

jq -s -e --arg request_id "${FAILURE_REQUEST_ID}" '
  [.[] | select(
    .event.dataset == "nginx.access"
    and .http.request.id == $request_id
  )] as $events
  | ($events | length) == 1
    and ($events[0].log.level == "ERROR")
    and ($events[0].event.outcome == "failure")
    and ($events[0].http.response.status_code == 502)
' "${EVENT_FILE}" >/dev/null || fail "Nginx Upstream 실패 이벤트가 일치하지 않습니다."

echo "Nginx observability tests passed"
