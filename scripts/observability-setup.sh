#!/usr/bin/env bash
set +x
set -euo pipefail

# filebeat-setup Container의 최초 초기화 진입점. 기존 팀 자원 발견 시 생성·갱신 중단.
: "${ELASTICSEARCH_URL:?ELASTICSEARCH_URL is required}"
: "${ELASTICSEARCH_USERNAME:?ELASTICSEARCH_USERNAME is required}"
: "${ELASTICSEARCH_PASSWORD:?ELASTICSEARCH_PASSWORD is required}"

if [[ ! "${ELASTICSEARCH_URL}" =~ ^https?://[^/?#@[:space:]]+(/[^?#@[:space:]]*)?$ \
  || "${ELASTICSEARCH_USERNAME}" == *:* ]]; then
  echo 'Elasticsearch URL·사용자명 형식 오류. 초기화 중단.' >&2
  exit 1
fi

elastic_url="${ELASTICSEARCH_URL%/}"
authorization="$(printf '%s:%s' "${ELASTICSEARCH_USERNAME}" "${ELASTICSEARCH_PASSWORD}" | base64 | tr -d '\r\n')"

# 인증 Header의 stdin 전달. 응답 원문·비밀번호 출력 및 Redirect·Proxy 사용 제외.
request_status() {
  local method="$1" endpoint="$2"
  local method_options=(--request GET)
  [[ "${method}" != HEAD ]] || method_options=(--head)

  printf 'header = "Authorization: Basic %s"\n' "${authorization}" \
    | curl --disable --config - --silent --noproxy '*' \
      --connect-timeout 5 --max-time 15 --proto '=http,https' \
      "${method_options[@]}" --output /dev/null --write-out '%{http_code}' \
      --url "${elastic_url}${endpoint}"
}

# 연결·인증 실패를 자원 부재로 처리하지 않도록 Root API부터 확인.
if ! status="$(request_status GET /)" || [[ "${status}" != 200 ]]; then
  echo 'Elasticsearch 연결·인증 확인 실패. 초기화 중단.' >&2
  exit 1
fi

# Index 조회에 같은 이름의 Data Stream·Alias 포함. 404 이외의 응답은 모두 중단.
for resource in \
  'HEAD /logs-omagotchi-prod' \
  'GET /_index_template/logs-omagotchi-prod' \
  'GET /_ilm/policy/omagotchi-logs'; do
  read -r method endpoint <<<"${resource}"
  if ! status="$(request_status "${method}" "${endpoint}")"; then
    echo "자원 조회 실패: ${endpoint}. 초기화 중단." >&2
    exit 1
  fi
  case "${status}" in
    404) ;;
    200)
      echo "기존 자원 발견: ${endpoint}. 삭제·덮어쓰기 없이 초기화 중단." >&2
      exit 1
      ;;
    *)
      echo "자원 부재 확인 불가: ${endpoint} (HTTP ${status}). 초기화 중단." >&2
      exit 1
      ;;
  esac
done

unset authorization
exec filebeat setup --index-management -e --strict.perms=false
