#!/usr/bin/env bash
set +x
set -euo pipefail

# 관측 설정만 필요한 별도 Compose 진입점. 애플리케이션 설정·이미지 SHA 검증과 분리.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SECRET_ENV_FILE="${SECRET_ENV_FILE:-${INFRA_DIR}/../secrets/prod.env}"

[[ -f "${SECRET_ENV_FILE}" ]] || {
  echo "서버 Secret 파일이 없습니다: ${SECRET_ENV_FILE}" >&2
  exit 1
}

# 호출 셸의 export 값보다 검토된 prod.env 우선.
unset ELASTICSEARCH_URL ELASTICSEARCH_USERNAME ELASTICSEARCH_PASSWORD
unset OPS_TELEGRAM_BOT_TOKEN OPS_TELEGRAM_CHAT_ID
unset GRAFANA_ADMIN_PASSWORD
# 이전 셸의 Profile 설정에 따른 초기화 Service의 우발적 기동 방지.
unset COMPOSE_PROFILES

# 연결된 공개 설정 파일의 내용·경로로 재생성 여부 판단. Secret·수집 데이터는 제외.
# Linux와 macOS의 기본 SHA-256 명령 지원.
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND=(sha256sum)
else
  HASH_COMMAND=(shasum -a 256)
fi

config_revision() (
  cd "${INFRA_DIR}/observability"
  find "$@" -type f ! -name '*.pyc' ! -name '.DS_Store' -print | LC_ALL=C sort |
    while IFS= read -r config_file; do
      "${HASH_COMMAND[@]}" "${config_file}"
    done | "${HASH_COMMAND[@]}" | cut -d ' ' -f 1
)

OBS_FILEBEAT_CONFIG_REVISION="$(config_revision filebeat/filebeat.yml)"
OBS_ELASTALERT_CONFIG_REVISION="$(config_revision elastalert2)"
OBS_PROMETHEUS_CONFIG_REVISION="$(config_revision prometheus)"
OBS_GRAFANA_CONFIG_REVISION="$(config_revision grafana/provisioning grafana/dashboards)"
OBS_COLLECTOR_CONFIG_REVISION="$(config_revision otel-collector/config.yaml)"
OBS_TEMPO_CONFIG_REVISION="$(config_revision tempo/config.yaml)"
export OBS_FILEBEAT_CONFIG_REVISION OBS_ELASTALERT_CONFIG_REVISION OBS_PROMETHEUS_CONFIG_REVISION
export OBS_GRAFANA_CONFIG_REVISION OBS_COLLECTOR_CONFIG_REVISION OBS_TEMPO_CONFIG_REVISION

exec docker compose \
  --project-name omagotchi-observability \
  --env-file "${SECRET_ENV_FILE}" \
  --file "${INFRA_DIR}/observability/compose.yaml" \
  "$@"
