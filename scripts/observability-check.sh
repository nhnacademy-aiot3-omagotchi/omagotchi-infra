#!/usr/bin/env bash
set +x
set -euo pipefail

# 중앙 로그 연결 전의 읽기 전용 확인.
# 비밀번호의 명령 인자·파일 저장 없이 버전·허용 작업·팀 저장소 상태만 출력.
# _has_privileges의 POST는 권한 조회이며 계정·Index 변경 없음.

for required_command in curl jq base64; do
  command -v "${required_command}" >/dev/null 2>&1 || {
    echo "필요한 명령이 없습니다: ${required_command}" >&2
    exit 1
  }
done

read -r -p 'Elasticsearch URL (http:// 또는 https:// 포함): ' elastic_url
read -r -p '기존 공용 계정 이름: ' elastic_user

if [[ ! "${elastic_url}" =~ ^https?://[^/?#@[:space:]]+(/[^?#@[:space:]]*)?$ \
  || -z "${elastic_user}" || "${elastic_user}" == *:* ]]; then
  echo 'URL·사용자명 확인 필요: URL 내 Credential·Query 금지, 사용자명 내 콜론 금지.' >&2
  exit 1
fi
elastic_url="${elastic_url%/}"

if [[ "${elastic_url}" == http://* ]]; then
  read -r -p 'HTTP는 암호화되지 않습니다. 학교 내부 보호망 주소가 맞으면 yes 입력: ' internal_network
  [[ "${internal_network}" == yes ]] || exit 1
fi

read -r -s -p '비밀번호 (화면 표시·파일 저장 없음): ' elastic_password
printf '\n' >&2
[[ -n "${elastic_password}" ]] || {
  echo '비밀번호가 비어 있습니다.' >&2
  exit 1
}
authorization="$(printf '%s:%s' "${elastic_user}" "${elastic_password}" | base64 | tr -d '\r\n')"
unset elastic_password elastic_user

# 공통 요청 경계: 제한 시간·TLS 검증 유지, 응답 원문 대신 허용된 필드만 출력.
check_endpoint() {
  local label="$1" method="$2" endpoint="$3" fields="$4" body="${5:-}"
  local response status curl_status
  local request_arguments=(
    --silent --connect-timeout 5 --max-time 15 --max-filesize 1048576
    --proto '=http,https' --request "${method}"
    --url "${elastic_url}${endpoint}" --write-out $'\n%{http_code}'
  )
  if [[ -n "${body}" ]]; then
    request_arguments+=(--header 'Content-Type: application/json' --data "${body}")
  fi

  # 인증 Header의 stdin 전달. 사용자 curl 설정·Redirect에 따른 의도하지 않은 전송 방지.
  if response="$(printf 'header = "Authorization: Basic %s"\n' "${authorization}" \
    | curl --disable --config - "${request_arguments[@]}" 2>/dev/null)"; then
    status="${response##*$'\n'}"
    response="${response%$'\n'*}"
  else
    curl_status=$?
    printf '%s: 연결 실패 (curl=%s, 인증서 오류 시 학교 CA 확인; -k 사용 금지)\n' \
      "${label}" "${curl_status}"
    return 1
  fi

  printf '%s: HTTP %s\n' "${label}" "${status}"
  [[ "${status}" == 200 ]] || return 1
  if ! printf '%s' "${response}" | jq -ce "${fields}"; then
    echo '예상한 JSON 필드가 없습니다. 응답 원문은 출력하지 않습니다.' >&2
    return 1
  fi
}

printf '접속 방식: %s\n' "${elastic_url%%:*}"
check_endpoint 'Elasticsearch 버전' GET '/' \
  'if (.version.number | type) == "string" then {version: .version.number} else error("version missing") end'

# 다른 팀의 권한·Index 목록 조회 없이 필요한 작업의 허용 여부만 확인.
check_endpoint '기존 계정의 허용 작업' POST '/_security/user/_has_privileges' \
  '{cluster, index}' \
  '{"cluster":["monitor","manage_index_templates","manage_ilm"],"index":[{"names":["logs-omagotchi-prod"],"privileges":["read","create_doc","view_index_metadata","manage"]},{"names":["elastalert-omagotchi-status*"],"privileges":["read","write","create_index","manage"]}]}' || true

check_endpoint 'Elasticsearch Data Node 수' GET \
  '/_cluster/health?filter_path=number_of_data_nodes' \
  '{number_of_data_nodes}' || true

check_endpoint '팀 Data Stream' GET '/_data_stream/logs-omagotchi-prod' \
  '{data_streams: [.data_streams[] | {name, template, ilm_policy}]}' || true

check_endpoint '팀 Index Template' GET '/_index_template/logs-omagotchi-prod' \
  '{index_templates: [.index_templates[] | {name, index_template: {index_patterns: .index_template.index_patterns, priority: .index_template.priority, owner: .index_template._meta.owner}}]}' || true

check_endpoint '팀 ILM' GET '/_ilm/policy/omagotchi-logs' \
  '{policy: .["omagotchi-logs"].policy}' || true

# 저장 없이 현재 적용 Template과 겹치는 Pattern 확인. 로그 문서 조회 없음.
check_endpoint '적용 Template Simulation' POST '/_index_template/_simulate_index/logs-omagotchi-prod' \
  '{settings: .template.settings, overlapping}' || true

unset authorization
echo '확인 종료: 계정·설정·Index·문서 변경 및 Telegram 전송 없음.'
echo '403은 해당 조회 불가, 404는 API 미지원 또는 대상 부재. 실제 쓰기·수집 성공과 별개.'
