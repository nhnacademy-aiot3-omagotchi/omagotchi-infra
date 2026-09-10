#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIRECTORY="$(mktemp -d)"
trap 'rm -rf -- "${TEST_DIRECTORY}"' EXIT
SOURCE_INFRA="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SOURCE_INFRA}/scripts/rolling-deploy.sh"

INFRA_DIR="${TEST_DIRECTORY}/infra"
DEPLOY_ENV="${INFRA_DIR}/deploy.env"
SMOKE_SCRIPT="${TEST_DIRECTORY}/smoke.sh"
mkdir -p "${INFRA_DIR}/.rollout" "${TEST_DIRECTORY}/containers"
printf '#!/usr/bin/env bash\nexit 0\n' >"${SMOKE_SCRIPT}"
chmod +x "${SMOKE_SCRIPT}"
old=1111111111111111111111111111111111111111
new=2222222222222222222222222222222222222222
events="${TEST_DIRECTORY}/events"
failure=""

fail() { echo "$1" >&2; exit 1; }

rolling_container() {
  [[ ! -f "${TEST_DIRECTORY}/containers/$1" ]] || printf '%s\n' "$1"
}

rolling_ready() {
  # A 교체 완료 뒤, B 교체 직전의 Discovery·반대 자리 검사 실패.
  if [[ "$(rolling_read IDENTITY_A_IMAGE_TAG "${DEPLOY_ENV}")" == "${new}" \
    && "$(cat "${TEST_DIRECTORY}/containers/identity-service-b")" == "${old}" ]]; then
    if [[ ( "$1" == identity-service-a && "${failure}" == peer-* ) \
      || ( "$1" == discovery-service && "${failure}" == discovery-after-a ) ]]; then
      printf 'peer-check\n' >>"${events}"
      if [[ "${failure}" != peer-once || "$(grep -c '^peer-check$' "${events}")" == 1 ]]; then
        echo "준비 검사 실패: $1 (HTTP 503)" >&2
        return 1
      fi
    fi
  fi
  if [[ "$1" == discovery-service ]]; then [[ "${failure}" != discovery ]]; return; fi
  [[ -f "${TEST_DIRECTORY}/containers/$1" ]] || return 1
  if [[ "$(cat "${TEST_DIRECTORY}/containers/$1")" == "${new}" ]]; then
    case "${failure}" in
      readiness:"$1"|rollback-drain:"$1"|inspect:"$1"|restarting:"$1") return 1 ;;
    esac
  fi
  return 0
}

# 실제 대기 함수 사용, 시간 경과만 대체한 반복 검사.
sleep() { SECONDS=$((SECONDS + 45)); }

rolling_compose() {
  local env_file="$1" target revision count
  shift
  printf 'compose:%s\n' "$*" >>"${events}"
  [[ -f "${env_file}" ]] || return 1
  if [[ "$1" == up ]]; then
    target="${*: -1}"
    revision="$(rolling_read "IDENTITY_$(printf '%s' "${target##*-}" | tr '[:lower:]' '[:upper:]')_IMAGE_TAG" "${env_file}")"
    printf 'start:%s:%s\n' "${target}" "${revision}" >>"${events}"
    if [[ "${failure}" == "start:${target}" && "${revision}" == "${new}" ]]; then
      rm -f "${TEST_DIRECTORY}/containers/${target}"
      return 1
    fi
    printf '%s\n' "${revision}" >"${TEST_DIRECTORY}/containers/${target}"
    count="$(find "${TEST_DIRECTORY}/containers" -type f | wc -l | tr -d ' ')"
    ((count <= 2)) || fail "교체 중 세 번째 인스턴스 생성"
  fi
}

rolling_drain() {
  printf 'drain:%s\n' "$2" >>"${events}"
  [[ "${failure}" != "drain:$2" ]] || return 1
  if [[ "${failure}" == "rollback-drain:$2" ]]; then
    [[ "$(cat "${TEST_DIRECTORY}/containers/$2")" != "${new}" ]]
  fi
}

rolling_admit() {
  printf 'admit:%s\n' "$2" >>"${events}"
  [[ -f "${TEST_DIRECTORY}/containers/$2" ]]
}

docker() {
  local target="${*: -1}"
  [[ "$1" == inspect ]] || return 1
  case "$3" in
    '{{.Config.Image}}') printf 'fixture:%s\n' "$(cat "${TEST_DIRECTORY}/containers/${target}")" ;;
    '{{.State.Status}}')
      [[ "${failure}" != "inspect:${target}" ]] || return 1
      if [[ "${failure}" == "restarting:${target}" ]]; then printf 'restarting\n'; else printf 'running\n'; fi
      ;;
    *) return 1 ;;
  esac
}

reset_case() {
  rm -f "${TEST_DIRECTORY}/containers/identity-service" \
    "${TEST_DIRECTORY}/containers/identity-service-a" "${TEST_DIRECTORY}/containers/identity-service-b" \
    "${INFRA_DIR}/.rollout/identity-service.state" "${INFRA_DIR}/.rollout/identity-service.state.env"
  printf 'IDENTITY_IMAGE_TAG=%s\nSMOKE_BASE_URL=https://example.invalid\n' "${old}" >"${DEPLOY_ENV}"
  printf '%s\n' "${old}" >"${TEST_DIRECTORY}/containers/identity-service-a"
  printf '%s\n' "${old}" >"${TEST_DIRECTORY}/containers/identity-service-b"
  : >"${events}"
  failure=""
  SMOKE_SCRIPT="${TEST_DIRECTORY}/smoke.sh"
}

# Given/When: 평소 A/B 두 개를 한 자리씩 교체.
reset_case
rolling_deploy identity-service "${new}" >/dev/null
# Then: 모두 검증한 뒤에만 논리 서비스의 성공 SHA 확정.
[[ "$(rolling_read IDENTITY_IMAGE_TAG "${DEPLOY_ENV}")" == "${new}" ]] || fail "성공 SHA 미확정"
[[ "$(grep -E '^(drain|start|admit):' "${events}")" == "drain:identity-service-a
start:identity-service-a:${new}
admit:identity-service-a
drain:identity-service-b
start:identity-service-b:${new}
admit:identity-service-b" ]] || fail "한 자리씩 제외·기동·복귀 순서 위반"

# Given/When: A 교체 후 반대 자리의 상태 검사에서 한 번만 발생한 503.
reset_case
failure="peer-once"
rolling_deploy identity-service "${new}" >/dev/null
# Then: 재확인 성공 후 B 교체, 완료된 A의 재생성 없음.
[[ "$(grep -c '^peer-check$' "${events}")" == 2 ]] || fail "일시적인 503의 재확인 누락"
[[ "$(grep -c '^start:identity-service-a:' "${events}")" == 1 ]] || fail "상태 재확인 중 완료된 A 재생성"
[[ "$(rolling_read IDENTITY_IMAGE_TAG "${DEPLOY_ENV}")" == "${new}" ]] || fail "상태 복구 후 배포 완료 누락"

# Given/When: A 교체 후 Discovery 또는 반대 자리의 상태 검사에서 지속되는 503.
for scenario in peer-down discovery-after-a; do
  reset_case
  failure="${scenario}"
  if rolling_deploy identity-service "${new}" >"${TEST_DIRECTORY}/failure.log" 2>&1; then
    fail "반대 자리·Discovery의 지속 장애를 배포 성공 처리"
  fi
  # Then: B 제외·교체 없이 중단, 검증된 A 기록 유지, 미완료 표시와 구분.
  ! grep -Eq '^(drain|start):identity-service-b' "${events}" || fail "상태 확인 실패 후 B 변경"
  [[ "$(rolling_read IDENTITY_A_IMAGE_TAG "${DEPLOY_ENV}")" == "${new}" ]] || fail "검증된 A 이미지 기록 유실"
  [[ "$(rolling_read IDENTITY_IMAGE_TAG "${DEPLOY_ENV}")" == "${old}" ]] || fail "부분 성공을 전체 성공으로 기록"
  [[ ! -e "${INFRA_DIR}/.rollout/identity-service.state" ]] || fail "완료된 자리의 미완료 표시 잔류"
  grep -Fq 'HTTP 503' "${TEST_DIRECTORY}/failure.log" || fail "마지막 상태 검사 실패 내용 누락"
  # When/Then: 정상 복구 뒤 파일을 수동으로 삭제하지 않고 재배포 가능.
  failure=""
  rolling_deploy identity-service "${new}" >/dev/null || fail "상태 복구 후 재배포 차단"
done

# Given/When: 각 슬롯의 새 이미지 기동 실패.
for slot in a b; do
  reset_case
  failure="start:identity-service-${slot}"
  if rolling_deploy identity-service "${new}" >/dev/null 2>&1; then fail "새 버전 기동 실패를 성공 처리"; fi
  # Then: 실패한 자리만 복구, 완료되지 않은 논리 SHA 유지.
  grep -Fq "start:identity-service-${slot}:${old}" "${events}" || fail "실패 슬롯 복구 누락"
  [[ "$(rolling_read IDENTITY_IMAGE_TAG "${DEPLOY_ENV}")" == "${old}" ]] || fail "부분 성공의 전체 성공 처리"
  if [[ "${slot}" == a ]]; then
    ! grep -Fq 'start:identity-service-b:' "${events}" || fail "첫 자리 실패 후 반대 자리 변경"
  else
    [[ "$(rolling_read IDENTITY_A_IMAGE_TAG "${DEPLOY_ENV}")" == "${new}" ]] || fail "이미 성공한 A 상태 유실"
  fi
done

# Given/When: 새 컨테이너 실행 후 준비 검사 실패.
for scenario in readiness rollback-drain inspect restarting; do
  reset_case
  failure="${scenario}:identity-service-a"
  if rolling_deploy identity-service "${new}" >/dev/null 2>&1; then fail "준비 검사 실패를 성공 처리"; fi
  # Then: 실행 중인 새 컨테이너 제외 확인 후에만 복구. 확인 불가 시 실행·진행 기록 유지.
  if [[ "${scenario}" == readiness ]]; then
    [[ "$(grep -E '^(drain|start|admit):' "${events}")" == "drain:identity-service-a
start:identity-service-a:${new}
drain:identity-service-a
start:identity-service-a:${old}
admit:identity-service-a" ]] || fail "준비 검사 실패 후 새 실행을 제외하지 않고 복구"
    [[ ! -e "${INFRA_DIR}/.rollout/identity-service.state" ]] || fail "복구 완료 후 미완료 기록 잔류"
  else
    ! grep -Fq "start:identity-service-a:${old}" "${events}" || fail "실행 상태·요청 제외 확인 실패 후 강제 복구"
    [[ "$(cat "${TEST_DIRECTORY}/containers/identity-service-a")" == "${new}" ]] || fail "확인 중인 새 실행 제거"
    [[ -s "${INFRA_DIR}/.rollout/identity-service.state" && -s "${INFRA_DIR}/.rollout/identity-service.state.env" ]] || fail "복구 판단용 기록 유실"
  fi
  [[ "$(rolling_read IDENTITY_IMAGE_TAG "${DEPLOY_ENV}")" == "${old}" ]] || fail "미완료 배포의 성공 SHA 기록"
  ! grep -Fq 'start:identity-service-b:' "${events}" || fail "복구 중 반대 자리 변경"
done

# Given/When: 기동은 성공했지만 외부 공개 경로 검사 실패.
reset_case
SMOKE_SCRIPT="$(type -P false)"
if rolling_deploy identity-service "${new}" >/dev/null 2>&1; then fail "공개 경로 오류의 배포 성공 처리"; fi
# Then: 첫 자리 복구, 반대 자리 교체 금지.
grep -Fq "start:identity-service-a:${old}" "${events}" || fail "공개 경로 실패 후 복구 누락"
! grep -Fq 'start:identity-service-b:' "${events}" || fail "공개 경로 오류 후 반대 자리 교체"

# Given/When: 호출자 반영 확인 실패.
reset_case
failure=drain:identity-service-a
if rolling_deploy identity-service "${new}" >/dev/null 2>&1; then fail "요청 제외 실패를 성공 처리"; fi
# Then: 기존 실행 유지, 새 기동 금지.
! grep -q '^start:' "${events}" || fail "요청 제외 확인 전 기존 실행 교체"

# Given/When: 비정상 종료의 미완료 기록.
for stage in replacing verified; do
  reset_case
  printf 'stage=%s\n' "${stage}" >"${INFRA_DIR}/.rollout/identity-service.state"
  if rolling_deploy identity-service "${new}" >/dev/null 2>&1; then fail "미완료 상태 무시"; fi
  # Then: 기존 기록을 단계 이름만으로 자동 삭제하지 않고 추가 변경 차단.
  [[ ! -s "${events}" ]] || fail "미완료 배포를 확인하기 전 변경 실행"
done

# Given/When: 한쪽 사전 장애.
reset_case
rm "${TEST_DIRECTORY}/containers/identity-service-b"
if rolling_deploy identity-service "${new}" >/dev/null 2>&1; then fail "한쪽 장애 중 정상 슬롯 교체 허용"; fi
[[ ! -s "${events}" ]] || fail "건강한 반대 슬롯 확인 전 변경 실행"

# Given/When: Discovery 장애 중 배포 요청.
reset_case
failure=discovery
if rolling_deploy identity-service "${new}" >/dev/null 2>&1; then fail "Discovery 장애 중 배포 허용"; fi
[[ ! -s "${events}" ]] || fail "Discovery 장애 중 Container 변경 실행"

# Given/When: 구형 단일 컨테이너만 있거나 A/B와 함께 남은 상태.
for configuration in single mixed; do
  reset_case
  if [[ "${configuration}" == single ]]; then
    rm "${TEST_DIRECTORY}/containers/identity-service-a" "${TEST_DIRECTORY}/containers/identity-service-b"
  fi
  printf '%s\n' "${old}" >"${TEST_DIRECTORY}/containers/identity-service"
  if rolling_deploy identity-service "${new}" >/dev/null 2>&1; then
    fail "구형 단일 컨테이너가 남은 배포 허용"
  fi
  # Then: 자동 전환·삭제 없이 기존 실행 보존, 추가 Compose 변경 없음.
  [[ -f "${TEST_DIRECTORY}/containers/identity-service" ]] || fail "구형 단일 컨테이너의 자동 삭제"
  [[ ! -s "${events}" ]] || fail "지원하지 않는 구성에서 Compose 변경 실행"
done
reset_case

# Given: Registry 편입·제외 확인 중 일시적 조회 실패와 지속 장애.
(
  docker() {
    case "$1" in
      ps) printf 'caller-container\n' ;;
      inspect)
        printf 'inspect\n' >>"${events}"
        if [[ "${registry_scenario}" == inspect-once && "$(grep -c '^inspect$' "${events}")" == 1 ]]; then return 1; fi
        printf 'frontend-a\n'
        ;;
      *) return 1 ;;
    esac
  }

  rolling_registry() {
    printf 'registry\n' >>"${events}"
    if [[ "${registry_scenario}" == registry-unavailable ]]; then return 1; fi
    if [[ "${registry_scenario}" == registry-once && "$(grep -c '^registry$' "${events}")" == 1 ]]; then return 1; fi
    if [[ "${present}" == true ]]; then
      printf '{"services":{"IDENTITY-SERVICE":["target","peer"]}}\n'
    else
      printf '{"services":{"IDENTITY-SERVICE":["peer"]}}\n'
    fi
  }

  for present in true false; do
    for registry_scenario in inspect-once registry-once registry-unavailable; do
      : >"${events}"
      # When/Then: 조회 복구 후에만 성공, 지속 장애는 제한 시간 이후 실패.
      if [[ "${registry_scenario}" == registry-unavailable ]]; then
        if rolling_wait_clients IDENTITY-SERVICE target "${present}" >/dev/null 2>&1; then
          fail "Registry 지속 장애의 반영 완료 처리"
        fi
        [[ "$(grep -c '^registry$' "${events}")" == 2 ]] || fail "Registry 장애의 제한 시간 내 재확인 누락"
      else
        rolling_wait_clients IDENTITY-SERVICE target "${present}" || fail "일시적인 조회 실패 후 재확인 누락"
        [[ "$(grep -c '^inspect$' "${events}")" == 2 ]] || fail "조회 실패를 재확인 없이 성공 처리"
      fi
    done
  done
)

# Given: 실제 Health 검사와 대기 함수, 컨테이너 명령 결과만 대체.
(
  # shellcheck disable=SC1091
  source "${SOURCE_INFRA}/scripts/rolling-deploy.sh"
  docker() {
    case "$1" in
      ps) printf 'frontend-container\n' ;;
      inspect) printf 'true\n' ;;
      exec)
        printf '%s\n' "${*: -1}" >>"${events}"
        if [[ "${*: -1}" == http://127.0.0.1:8080/actuator/health ]]; then
          printf '503'
          return 22
        fi
        printf '200'
        ;;
      *) return 1 ;;
    esac
  }
  : >"${events}"
  # When/Then: readiness 성공·의존성 Health 실패 시 재확인 후 대상·URL·상태 출력.
  if rolling_wait_ready frontend-a >"${TEST_DIRECTORY}/health.log" 2>&1; then
    fail "의존성 Health의 503을 준비 완료 처리"
  fi
  grep -Fq 'frontend-a (http://127.0.0.1:8080/actuator/health, HTTP 503)' \
    "${TEST_DIRECTORY}/health.log" || fail "Health 실패의 대상·URL·상태 누락"
  [[ "$(grep -c '/actuator/health$' "${events}")" == 2 ]] || fail "실제 Health 검사 함수의 재확인 누락"
)

# Given: 실제 분배 파일 생성·교체 함수와 Nginx 명령 결과의 대역.
(
  rolling_container() { [[ "$1" == nginx ]] && printf 'nginx\n'; }
  rolling_ready() { [[ "$1" == frontend-a || "$1" == frontend-b ]]; }
  docker() {
    [[ "$1" == exec && "$2" == nginx ]] || return 1
    case "$3 $4" in
      'nginx -t') [[ "${route_scenario}" != invalid-config ]] ;;
      'nginx -s')
        printf 'reload\n' >>"${events}"
        [[ "${route_scenario}" != reload-failure ]]
        ;;
      'sh -c')
        if [[ -s "${events}" ]]; then printf '202\n'; else printf '101\n'; fi
        ;;
      *) return 1 ;;
    esac
  }

  for route_scenario in success invalid-config reload-failure; do
    INFRA_DIR="${TEST_DIRECTORY}/route-${route_scenario}"
    directory="${INFRA_DIR}/nginx/conf.d/runtime"
    mkdir -p "${INFRA_DIR}/nginx/conf.d"
    cp "${SOURCE_INFRA}/nginx/conf.d/default.conf" "${INFRA_DIR}/nginx/conf.d/default.conf"
    rolling_initialize_routes
    cp "${directory}/upstreams.conf" "${directory}/upstreams.expected"
    cp "${directory}/frontend.servers" "${directory}/frontend.expected"
    : >"${events}"

    # When/Then: 성공 시 새 목록 유지, 후보 검사·Reload 실패 시 직전 두 파일 유지.
    if [[ "${route_scenario}" == success ]]; then
      rolling_route frontend frontend-a false || fail "정상 Nginx 분배 목록 적용 실패"
      ! grep -Fq 'frontend-a:8080' "${directory}/upstreams.conf" || fail "요청 제외 대상의 분배 목록 잔류"
      [[ "$(cat "${directory}/frontend.servers")" == 'server frontend-b:8080 resolve;' ]] || fail "정상 반대 자리의 분배 목록 유실"
      [[ ! -e "${directory}/upstreams.previous" && ! -e "${directory}/frontend.previous" ]] || fail "성공 후 복구용 파일 잔류"
    else
      if rolling_route frontend frontend-a false >/dev/null 2>&1; then fail "Nginx 실패를 성공 처리"; fi
      cmp -s "${directory}/upstreams.conf" "${directory}/upstreams.expected" || fail "실패 후 전체 분배 목록 불일치"
      cmp -s "${directory}/frontend.servers" "${directory}/frontend.expected" || fail "실패 후 서비스 분배 목록 불일치"
      if [[ "${route_scenario}" == invalid-config ]]; then
        [[ ! -s "${events}" ]] || fail "잘못된 후보 설정의 Reload 실행"
      fi
    fi
  done
)

echo "Rolling deployment order and recovery tests passed"
