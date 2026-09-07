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
  local exit_status=$?

  # 실패 원인 보존을 위한 테스트 전용 Container의 삭제 전 진단.
  if ((exit_status != 0)); then
    docker inspect --format '{{.Name}}: {{.State.Status}}' \
      "${PROXY_NAME}" "${UPSTREAM_NAME}" >&2 || true
    docker logs --tail=30 "${PROXY_NAME}" >&2 || true
    docker logs --tail=30 "${UPSTREAM_NAME}" >&2 || true
    docker exec "${PROXY_NAME}" tail -n 30 /var/log/nginx/error.log >&2 || true
  fi

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

wait_until_upstreams_ready() {
  local port="$1"
  local path
  local response_status

  # 자체 /health와 별개인 동적 DNS 해석·모의 Gateway·Frontend 연결 준비.
  # Request ID 검증은 준비 확인 이후 별도 요청에서 수행.
  for path in /api/v1/rules/readiness /test-readiness; do
    for _ in {1..30}; do
      response_status="$(curl --silent --show-error \
        --connect-timeout 1 --max-time 2 \
        --output /dev/null --write-out '%{http_code}' \
        "http://127.0.0.1:${port}${path}" 2>/dev/null || true)"
      if [[ "${response_status}" == "204" ]]; then
        break
      fi
      sleep 0.2
    done

    [[ "${response_status}" == "204" ]] ||
      fail "Nginx 경유 요청 준비 실패: ${path} (HTTP ${response_status})"
  done
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
wait_until_upstreams_ready "${PROXY_PORT}"

API_HEADERS="${TEMP_DIR}/api-headers"
curl --silent --show-error \
  --dump-header "${API_HEADERS}" \
  --output /dev/null \
  --header "X-Request-ID: ${SPOOFED_REQUEST_ID}" \
  --header "Authorization: Bearer ${SENSITIVE_VALUE}" \
  --data "${SENSITIVE_VALUE}" \
  "http://127.0.0.1:${PROXY_PORT}/api/v1/rules/${SENSITIVE_VALUE}?secret=${SENSITIVE_VALUE}"

[[ "$(status_code "${API_HEADERS}")" == "204" ]] ||
  fail "Gateway 정상 요청 실패: HTTP $(status_code "${API_HEADERS}")"
API_REQUEST_ID="$(response_request_id "API 요청" "${API_HEADERS}")"
[[ "${API_REQUEST_ID}" != "${SPOOFED_REQUEST_ID}" ]] ||
  fail "외부 Request ID가 Nginx 경계에서 교체되지 않았습니다."
[[ "$(header_value "X-Received-Request-ID" "${API_HEADERS}")" == "${API_REQUEST_ID}" ]] ||
  fail "Gateway 전달값과 응답 Request ID가 일치하지 않습니다."

FRONTEND_HEADERS="${TEMP_DIR}/frontend-headers"
curl --silent --show-error \
  --dump-header "${FRONTEND_HEADERS}" \
  --output /dev/null \
  --header "X-Request-ID: ${SPOOFED_REQUEST_ID}" \
  "http://127.0.0.1:${PROXY_PORT}/admin/audit"

[[ "$(status_code "${FRONTEND_HEADERS}")" == "204" ]] ||
  fail "Frontend 정상 요청 실패: HTTP $(status_code "${FRONTEND_HEADERS}")"
FRONTEND_REQUEST_ID="$(response_request_id "Frontend 요청" "${FRONTEND_HEADERS}")"
[[ "${FRONTEND_REQUEST_ID}" != "${SPOOFED_REQUEST_ID}" ]] ||
  fail "외부 Request ID가 Frontend 경계에서 교체되지 않았습니다."
[[ "$(header_value "X-Received-Request-ID" "${FRONTEND_HEADERS}")" == "${FRONTEND_REQUEST_ID}" ]] ||
  fail "Frontend 전달값과 응답 Request ID가 일치하지 않습니다."

for path in /actuator /actuator/prometheus /actuator/health; do
  [[ "$(curl --silent --show-error --max-time 5 --output /dev/null --write-out '%{http_code}' \
    "http://127.0.0.1:${PROXY_PORT}${path}")" == 404 ]] || fail "내부 Actuator 외부 노출: ${path}"
done

# IP·Host Header와 무관한 두 OTP 용도의 공통 예산 확인.
# 초당 2건 전달 중 회복되는 분당 한도를 고려한 시도 상한, 첫 429에서 중단.
for attempt in {1..80}; do
  OTP_KIND=signup
  if ((attempt % 2 == 0)); then OTP_KIND=password-reset; fi
  curl --silent --show-error --max-time 20 \
    --dump-header "${TEMP_DIR}/otp-headers" --output "${TEMP_DIR}/otp-body" \
    --header "CF-Connecting-IP: 198.51.100.${attempt}" --header "Host: otp-${attempt}.test" --request POST \
    "http://127.0.0.1:${PROXY_PORT}/bff/v2/auth/${OTP_KIND}/email-otp"
  if ((attempt <= 30)); then
    [[ "$(status_code "${TEMP_DIR}/otp-headers")" == 204 ]] || fail "한 반 30건의 정상 OTP 요청 차단"
  fi
  result="$(status_code "${TEMP_DIR}/otp-headers")"
  if [[ "${result}" == 429 ]]; then break; fi
  [[ "${result}" == 204 ]] || fail "합산 제한 검증 중 예상 밖 응답: ${result}"
done
[[ "$(status_code "${TEMP_DIR}/otp-headers")" == 429 ]] || fail "OTP 합산 제한 미적용"
OTP_REQUEST_ID="$(response_request_id 'OTP 제한' "${TEMP_DIR}/otp-headers")"
[[ "$(header_value Retry-After "${TEMP_DIR}/otp-headers")" == 60 ]] || fail "OTP Retry-After 누락"
[[ "$(header_value X-Content-Type-Options "${TEMP_DIR}/otp-headers")" == nosniff ]] || fail "OTP 오류의 보안 Header 누락"
[[ -z "$(header_value X-Received-Request-ID "${TEMP_DIR}/otp-headers")" ]] || fail "차단된 OTP의 Upstream 전달"
jq -e --arg request_id "${OTP_REQUEST_ID}" '
  .code == "COMMON_TOO_MANY_REQUESTS" and .requestId == $request_id
' "${TEMP_DIR}/otp-body" >/dev/null || fail "OTP 공통 오류 응답 불일치"
docker logs "${UPSTREAM_NAME}" 2>&1 | grep -Fq "${OTP_REQUEST_ID}" && fail "차단된 OTP의 Upstream 도달"

# OTP 예산 소진 후에도 조회·다른 BFF·API 요청 허용
for path in /register /bff/v2/auth/signup/email-otp /api/v1/rules/ping; do
  [[ "$(curl --silent --show-error --max-time 5 --output /dev/null --write-out '%{http_code}' \
    "http://127.0.0.1:${PROXY_PORT}${path}")" == 204 ]] || fail "OTP 외 요청의 오차단: ${path}"
done

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

jq -s -e --arg request_id "${FRONTEND_REQUEST_ID}" '
  [.[] | select(
    .event.dataset == "nginx.access"
    and .http.request.id == $request_id
  )] as $events
  | ($events | length) == 1
    and ($events[0].event.outcome == "success")
    and ($events[0].http.response.status_code == 204)
    and ($events[0].omagotchi.http.route == "/**")
' "${EVENT_FILE}" >/dev/null || fail "Frontend 접근 이벤트가 일치하지 않습니다."

echo "Nginx observability tests passed"
