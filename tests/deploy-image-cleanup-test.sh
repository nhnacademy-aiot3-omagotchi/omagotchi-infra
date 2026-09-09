#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP_DIR}"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

# 실제 Docker 삭제 대신 호출 대상과 배포 상태를 기록하는 대역 사용.
# shellcheck disable=SC1091
source "${INFRA_DIR}/scripts/deploy-service.sh"

current_sha="$(printf '%040d' 3)"
previous_sha="$(printf '%040d' 2)"
unused_sha="$(printf '%040d' 1)"
fixture_current_id="sha256:$(printf '%064d' 3)"
fixture_previous_id="sha256:$(printf '%064d' 2)"
unused_id="sha256:$(printf '%064d' 1)"
running_id="sha256:$(printf '%064d' 4)"
stopped_id="sha256:$(printf '%064d' 5)"
repository="ghcr.io/nhnacademy-aiot3-omagotchi/omagotchi-frontend"
deleted_file="${TEST_TMP_DIR}/deleted"
calls_file="${TEST_TMP_DIR}/calls"
failure=""

docker() {
  printf '%s\n' "$*" >>"${calls_file}"
  case "$1 $2" in
  'image inspect')
    [[ "${failure}" != inspect ]] || return 1
    case "${*: -1}" in
    "${repository}:${current_sha}") printf '%s\n' "${fixture_current_id}" ;;
    "${repository}:${previous_sha}") printf '%s\n' "${fixture_previous_id}" ;;
    *) return 1 ;;
    esac
    ;;
  'image ls')
    [[ "${failure}" != list ]] || return 1
    # 보존 이미지의 별도 SHA 태그·비대상 저장소·비 SHA 태그 포함.
    printf '%s\n' \
      "${repository}:${current_sha} ${fixture_current_id}" \
      "${repository}:${previous_sha} ${fixture_previous_id}" \
      "${repository}:$(printf '%040d' 8) ${fixture_current_id}" \
      "${repository}:$(printf '%040d' 9) ${fixture_previous_id}" \
      "${repository}:$(printf '%040d' 4) ${running_id}" \
      "${repository}:$(printf '%040d' 5) ${stopped_id}" \
      "${repository}-other:${unused_sha} ${unused_id}" \
      "ghcr.io/other-team/omagotchi-frontend:${unused_sha} ${unused_id}" \
      "${repository}:main ${unused_id}" \
      "${repository}:manual ${unused_id}" \
      "<none>:<none> ${unused_id}" \
      "${repository}:${unused_sha} ${unused_id}"
    ;;
  'container ls')
    [[ "$*" == "container ls --all --quiet --filter ancestor="* ]] || return 1
    [[ "${failure}" != containers ]] || return 1
    case "${*: -1}" in
    "ancestor=${running_id}") printf 'running-container\n' ;;
    "ancestor=${stopped_id}") printf 'stopped-container\n' ;;
    esac
    ;;
  'image rm')
    [[ "$*" == "image rm --no-prune ${repository}:${unused_sha}" ]] || return 1
    [[ "${failure}" != remove ]] || return 1
    printf '%s\n' "${*: -1}" >>"${deleted_file}"
    ;;
  *) return 1 ;;
  esac
}

# 현재·직전 성공 이미지, 별칭, 실행·중지 Container 참조, 비대상 저장소 보존.
: >"${deleted_file}"
# 위에서 불러온 실제 함수 호출. 아래의 같은 이름 함수는 배포 흐름 검증용 대역.
# shellcheck disable=SC2218
cleanup_service_images frontend "${current_sha}" "${previous_sha}" >/dev/null
[[ "$(<"${deleted_file}")" == "${repository}:${unused_sha}" ]] ||
  fail "사용하지 않는 과거 SHA 태그만 삭제하지 못했습니다."

# 같은 SHA 재배포와 잘못된 입력의 Docker 호출 금지.
: >"${calls_file}"
# shellcheck disable=SC2218
cleanup_service_images frontend "${current_sha}" "${current_sha}"
if cleanup_service_images nginx "${current_sha}" "${previous_sha}"; then
  fail "허용하지 않은 서비스의 이미지 정리가 실행됐습니다."
fi
if cleanup_service_images frontend invalid "${previous_sha}"; then
  fail "올바르지 않은 SHA의 이미지 정리가 실행됐습니다."
fi
[[ ! -s "${calls_file}" ]] || fail "정리 생략 대상에서 Docker가 호출됐습니다."

# 조회 실패 시 삭제 금지, 삭제 실패의 호출자 전파.
for failure in inspect list containers remove; do
  : >"${deleted_file}"
  if cleanup_service_images frontend "${current_sha}" "${previous_sha}" >/dev/null 2>&1; then
    fail "이미지 정리 실패가 감지되지 않았습니다: ${failure}"
  fi
  [[ ! -s "${deleted_file}" ]] || fail "조회·삭제 실패 이후 삭제가 진행됐습니다: ${failure}"
done

# 실제 배포 진입점의 성공 이후 정리 검증. 슬롯별 실패 복구는 rolling-deploy-test.sh 담당.
DEPLOY_ENV="${TEST_TMP_DIR}/deploy.env"
SECRET_ENV="${TEST_TMP_DIR}/prod.env"
ROOT_DIR="${TEST_TMP_DIR}"
COMPOSE_SCRIPT="$(type -P true)"
SMOKE_SCRIPT="${COMPOSE_SCRIPT}"
touch "${SECRET_ENV}"
events_file="${TEST_TMP_DIR}/events"
output_file="${TEST_TMP_DIR}/output"
failure=""
SCRIPT_DIR="${TEST_TMP_DIR}/scripts"
mkdir -p "${SCRIPT_DIR}"
cat >"${SCRIPT_DIR}/rolling-deploy.sh" <<'EOF'
rolling_initialize_routes() { :; }
rolling_read() { read_env "$@"; }
rolling_deploy() {
  printf 'rolling\n' >>"${events_file}"
  [[ "${failure}" != rolling ]] || return 1
  printf 'FRONTEND_IMAGE_TAG=%s\nSMOKE_BASE_URL=https://example.invalid\n' "$2" >"${DEPLOY_ENV}"
}
EOF

acquire_deploy_lock() {
  printf 'lock\n' >>"${events_file}"
}

cleanup_service_images() {
  # 정리 시점에 검증 완료 SHA 확정 여부 확인.
  printf 'cleanup:%s:%s\n' "$*" "$(read_env FRONTEND_IMAGE_TAG "${DEPLOY_ENV}")" >>"${events_file}"
  [[ "${failure}" != cleanup ]]
}

for failure in none rolling cleanup; do
  printf 'FRONTEND_IMAGE_TAG=%s\nSMOKE_BASE_URL=https://example.invalid\n' \
    "${previous_sha}" >"${DEPLOY_ENV}"
  : >"${events_file}"

  # errexit 동작 보존을 위해 조건문 밖의 자식 Shell에서 배포 수행.
  set +e
  (set -e; deploy_service_main frontend "${current_sha}") >"${output_file}" 2>&1
  result=$?
  set -e

  if [[ "${failure}" == none || "${failure}" == cleanup ]]; then
    [[ "${result}" == 0 ]] || fail "정상 배포 또는 정리 실패가 배포 실패로 처리됐습니다: ${failure}"
    [[ "$(read_env FRONTEND_IMAGE_TAG "${DEPLOY_ENV}")" == "${current_sha}" ]] ||
      fail "성공한 배포의 SHA가 확정되지 않았습니다."
    expected="$(printf 'lock\nrolling\ncleanup:frontend %s %s:%s' \
      "${current_sha}" "${previous_sha}" "${current_sha}")"
    [[ "$(<"${events_file}")" == "${expected}" ]] ||
      fail "배포 Lock·A/B 교체 성공·상태 확정 후 정리 순서 오류."
    if [[ "${failure}" == cleanup ]]; then
      grep -Fq '경고: 이전 이미지 정리 실패' "${output_file}" || fail "정리 실패 경고 누락."
    fi
  else
    [[ "${result}" != 0 ]] || fail "실패한 배포가 성공으로 처리됐습니다: ${failure}"
    [[ "$(read_env FRONTEND_IMAGE_TAG "${DEPLOY_ENV}")" == "${previous_sha}" ]] ||
      fail "실패한 배포에서 기존 확정 SHA가 변경됐습니다."
    if grep -Fq 'cleanup:' "${events_file}"; then
      fail "실패한 배포에서 이미지 정리가 실행됐습니다: ${failure}"
    fi
  fi
done

echo "Deploy image cleanup tests passed"
