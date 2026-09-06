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
printf 'called\n' >>"${CHECK_TEST_EVENTS}"
[[ "$1" == --disable && "$*" != *fixture-password* ]] || exit 90
IFS= read -r authorization
[[ "${authorization}" == 'header = "Authorization: Basic '* ]] || exit 91
proxy_bypassed=false
while (( $# )); do
  if [[ "$1" == --noproxy ]]; then
    shift
    [[ "$1" == '*' ]] || exit 92
    proxy_bypassed=true
  fi
  shift
done
[[ "${proxy_bypassed}" == true ]] || exit 93
# 인증 전달·Proxy 우회 확인 후 연결 실패 반환. 실제 네트워크 사용 없음.
exit 7
EOF
chmod +x "${TEST_TMP_DIR}/bin/curl"

# 루트 URL의 연결 시도와 하위 경로의 연결 전 거절 구분.
while read -r elastic_url expected; do
  : >"${TEST_TMP_DIR}/events"
  if {
    printf '%s\nfixture-user\n' "${elastic_url}"
    [[ "${elastic_url}" != http://* ]] || printf 'yes\n'
    printf 'fixture-password\n'
  } | CHECK_TEST_EVENTS="${TEST_TMP_DIR}/events" PATH="${TEST_TMP_DIR}/bin:${PATH}" \
    bash "${INFRA_DIR}/scripts/observability-check.sh" >"${TEST_TMP_DIR}/output" 2>&1; then
    fail '연결 실패 또는 잘못된 URL의 정상 종료'
  fi
  if [[ "${expected}" == requested ]]; then
    [[ -s "${TEST_TMP_DIR}/events" ]] || fail "루트 URL 연결 미시도: ${elastic_url}"
    grep -Fq '연결 실패 (curl=7,' "${TEST_TMP_DIR}/output" || fail '인증 전달·Proxy 우회 오류'
  else
    [[ ! -s "${TEST_TMP_DIR}/events" ]] || fail "잘못된 URL의 연결 시도: ${elastic_url}"
    grep -Fq '루트 URL' "${TEST_TMP_DIR}/output" || fail 'URL 형식 오류 안내 누락'
  fi
done <<'EOF'
http://example.invalid:9200 requested
http://example.invalid:9200/ requested
https://example.invalid:9200 requested
https://example.invalid:9200/ requested
http://example.invalid:9200/elasticsearch rejected
http://example.invalid:9200/elasticsearch/ rejected
http://example.invalid:9200// rejected
EOF

echo '중앙 로그 연결 전 URL·인증 전달·Proxy 우회 테스트 통과'
