#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP_DIR}"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

mkdir "${TEST_TMP_DIR}/bin"
cat >"${TEST_TMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# 요청의 인증 전달·조회 방식 확인. 실제 네트워크 사용 없음.
[[ "$*" != *"${ELASTICSEARCH_PASSWORD}"* ]] || exit 90
IFS= read -r authorization
[[ "${authorization}" == 'header = "Authorization: Basic '* ]] || exit 91
method=GET
endpoint=""
while (( $# )); do
  case "$1" in
    --head) method=HEAD ;;
    --url) shift; endpoint="${1#"${ELASTICSEARCH_URL}"}" ;;
  esac
  shift
done
printf '%s %s\n' "${method}" "${endpoint}" >>"${SETUP_TEST_EVENTS}"
case "${endpoint}" in
  / | /_ilm/policy/omagotchi-logs | /_index_template/logs-omagotchi-prod) [[ "${method}" == GET ]] || exit 92 ;;
  /logs-omagotchi-prod) [[ "${method}" == HEAD ]] || exit 93 ;;
  *) exit 94 ;;
esac
if [[ "${endpoint}" == "${SETUP_TEST_ENDPOINT}" ]]; then
  [[ "${SETUP_TEST_STATUS}" != timeout ]] || exit 28
  printf '%s' "${SETUP_TEST_STATUS}"
elif [[ "${endpoint}" == / ]]; then
  printf '200'
else
  printf '404'
fi
EOF

cat >"${TEST_TMP_DIR}/bin/filebeat" <<'EOF'
#!/usr/bin/env bash
printf 'filebeat %s\n' "$*" >>"${SETUP_TEST_EVENTS}"
EOF
chmod +x "${TEST_TMP_DIR}/bin/curl" "${TEST_TMP_DIR}/bin/filebeat"

# 모두 부재인 최초 실행만 허용. 기존 자원·인증 오류·조회 실패의 초기화 차단.
while read -r endpoint status expected; do
  : >"${TEST_TMP_DIR}/events"
  result=blocked
  if ELASTICSEARCH_URL=http://example.invalid:9200 \
    ELASTICSEARCH_USERNAME=fixture-user ELASTICSEARCH_PASSWORD=fixture-password \
    SETUP_TEST_ENDPOINT="${endpoint}" SETUP_TEST_STATUS="${status}" \
    SETUP_TEST_EVENTS="${TEST_TMP_DIR}/events" PATH="${TEST_TMP_DIR}/bin:${PATH}" \
    bash "${INFRA_DIR}/scripts/observability-setup.sh" >"${TEST_TMP_DIR}/output" 2>&1; then
    result=allowed
  fi
  [[ "${result}" == "${expected}" ]] || fail "초기화 허용 여부 오류: ${endpoint} ${status}"
  if [[ "${expected}" == allowed ]]; then
    grep -Fxq 'filebeat setup --index-management -e --strict.perms=false' "${TEST_TMP_DIR}/events" \
      || fail '자원 부재 확인 후 내장 초기화 미실행'
    [[ "$(wc -l <"${TEST_TMP_DIR}/events" | tr -d '[:space:]')" == 5 ]] \
      || fail '연결·세 자원 확인·초기화의 실행 순서 누락'
  elif grep -q '^filebeat ' "${TEST_TMP_DIR}/events"; then
    fail '조회 실패 또는 기존 자원 발견 후 초기화 실행'
  fi
  if grep -Eq 'fixture-password|Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ=' "${TEST_TMP_DIR}/output"; then
    fail '초기화 로그에 인증 정보 노출'
  fi
done <<'EOF'
/ 200 allowed
/ 401 blocked
/ 404 blocked
/logs-omagotchi-prod 200 blocked
/_index_template/logs-omagotchi-prod 200 blocked
/_ilm/policy/omagotchi-logs 200 blocked
/_index_template/logs-omagotchi-prod 403 blocked
/_ilm/policy/omagotchi-logs 500 blocked
/logs-omagotchi-prod 302 blocked
/logs-omagotchi-prod timeout blocked
EOF

echo '중앙 로그 최초 초기화 보호 테스트 통과'
