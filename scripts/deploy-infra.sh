#!/usr/bin/env bash

# 설정 동기화 진입점의 잠금·Git 갱신 이후 호출하는 Infra 반영 함수.
# Nginx·Cloudflared·관측 도구만 갱신, 앱·Discovery·Rule의 교체 제외.
# 호출 전제: INFRA_DIR·DEPLOY_ENV·SECRET_ENV·COMPOSE_SCRIPT와 pipefail 설정.
# 부분 실패 시 이미 반영한 구성 유지, 전체 자동 Rollback 미제공.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "Deploy Infrastructure Workflow로 실행하세요. 이 파일의 단독 실행은 지원하지 않습니다." >&2
  exit 64
fi

deploy_infrastructure() {
  local SMOKE_SCRIPT="${INFRA_DIR}/scripts/smoke-test.sh"
  local ROLLING_DEPLOY_SCRIPT="${INFRA_DIR}/scripts/rolling-deploy.sh"
  local OBSERVABILITY_DEPLOY_SCRIPT="${INFRA_DIR}/scripts/deploy-observability.sh"
  local base_url
  base_url="$(awk -F= '$1 == "SMOKE_BASE_URL" { print substr($0, index($0, "=") + 1); exit }' "${DEPLOY_ENV}")" || return 1
  if [[ ! "${base_url}" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "deploy.env의 SMOKE_BASE_URL이 올바르지 않습니다." >&2
    return 1
  fi

  # 이전 배포의 umask 077로 제한된 관측 Bind Mount 권한 복구.
  # 공개 설정·코드만 대상, secrets·deploy.env·JWT Key는 제외.
  chmod 755 \
    observability/elasticsearch \
    observability/elastalert2 \
    observability/elastalert2/rules \
    scripts/observability-setup.sh || return 1
  chmod 644 \
    observability/filebeat/filebeat.yml \
    observability/filebeat/setup.yml \
    observability/elasticsearch/index-template.json \
    observability/elasticsearch/lifecycle-policy.json \
    observability/elastalert2/runtime.py \
    observability/elastalert2/bootstrap.py \
    observability/elastalert2/telegram_alert.py \
    observability/elastalert2/config.yaml \
    observability/elastalert2/rules/application-error.yaml || return 1

  [[ -x "${COMPOSE_SCRIPT}" ]] || { echo "compose.sh 실행 권한이 없습니다." >&2; return 1; }
  [[ -x "${SMOKE_SCRIPT}" ]] || { echo "smoke-test.sh 실행 권한이 없습니다." >&2; return 1; }
  [[ -r "${OBSERVABILITY_DEPLOY_SCRIPT}" ]] || { echo "deploy-observability.sh를 읽을 수 없습니다." >&2; return 1; }

  # shellcheck disable=SC1090
  source "${ROLLING_DEPLOY_SCRIPT}" || return 1
  rolling_compose "${DEPLOY_ENV}" config --quiet || return 1
  rolling_initialize_routes || return 1

  # 앱 교체 없이 공용 진입점 설정 반영.
  rolling_compose "${DEPLOY_ENV}" up -d --no-deps --wait --wait-timeout 300 nginx cloudflared || return 1
  # SSH로 받은 상위 스크립트의 표준 입력 소비 방지.
  rolling_compose "${DEPLOY_ENV}" exec -T --interactive=false nginx nginx -t || return 1
  rolling_compose "${DEPLOY_ENV}" exec -T --interactive=false nginx nginx -s reload || {
    echo "Nginx 설정 검증 또는 reload 실패. 외부 Route 반영 상태를 확인하세요." >&2
    return 1
  }

  "${SMOKE_SCRIPT}" "${base_url}" || return 1

  # 동일한 배포 Lock·Revision 안에서 별도 Compose 프로젝트 갱신.
  # 관측성 실패 시 이미 배포된 업무 서비스 유지, 전체 배포의 성공 처리 차단.
  echo "::group::관측성 배포"
  if SECRET_ENV_FILE="${SECRET_ENV}" bash "${OBSERVABILITY_DEPLOY_SCRIPT}" </dev/null; then
    echo "::endgroup::"
  else
    echo "::endgroup::"
    echo "관측성 배포 실패. 업무 서비스는 유지되며, 관측성 상태 확인 후 Infra 배포 재실행이 필요합니다." >&2
    return 1
  fi

  echo "인프라 배포 완료: 앱 교체 제외"
}
