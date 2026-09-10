#!/usr/bin/env bash

# 일반 앱의 고정 A/B 배포 함수. deploy-infra.sh·deploy-service.sh의 배포 Lock 안에서 호출.
# rolling_deploy·rolling_migrate_single: 평상시 교체와 최초 전환 순서.
# 나머지 함수: Compose·Eureka·Nginx 상태 확인과 변경.
# 이 파일을 직접 실행하지 않고 배포 진입점에서 source로 사용.
# 호출 전제: 공용 배포 Lock 획득, Bash의 pipefail 설정.
# 호출자 제공 경로: INFRA_DIR·DEPLOY_ENV·SECRET_ENV·COMPOSE_SCRIPT·SMOKE_SCRIPT.

# 진입 흐름: 사전 확인 → 첫 전환 또는 A/B 교체 → 두 자리의 성공 버전 확정.
rolling_deploy() {
  local logical="$1" desired="$2" prefix journal candidate_env_file slot target peer key previous legacy
  local failed=false base_url container container_status
  case "${logical}" in
    frontend) prefix=FRONTEND ;;
    gateway-service) prefix=GATEWAY ;;
    identity-service) prefix=IDENTITY ;;
    learning-service) prefix=LEARNING ;;
    prediction-service) prefix=PREDICTION ;;
    *) return 1 ;;
  esac
  [[ "${desired}" =~ ^[0-9a-f]{40}$ ]] || return 1
  command -v jq >/dev/null || return 1
  base_url="$(rolling_read SMOKE_BASE_URL "${DEPLOY_ENV}")" || return 1
  [[ "${base_url}" =~ ^https?://[^[:space:]]+$ ]] || return 1
  rolling_wait_ready discovery-service || { echo "Discovery 준비 상태 확인 실패. 기존 앱 유지" >&2; return 1; }
  mkdir -p "${INFRA_DIR}/.rollout" || return 1
  journal="${INFRA_DIR}/.rollout/${logical}.state"
  if [[ -e "${journal}" ]]; then
    echo "미완료 배포 기록 존재: ${journal}. 현재 슬롯·경로 확인 후 복구 필요" >&2
    return 1
  fi
  candidate_env_file="${journal}.env"
  cp "${DEPLOY_ENV}" "${candidate_env_file}" || return 1
  legacy="$(rolling_container "${logical}")" || return 1
  if [[ -n "${legacy}" ]]; then
    # 첫 전환은 A 생성 → 단일 인스턴스 제외·종료 → B 생성, 최대 두 개 유지.
    [[ -z "$(rolling_container "${logical}-a")" && -z "$(rolling_container "${logical}-b")" ]] || {
      echo "단일·A/B 인스턴스 혼재. 자동 전환 중단: ${logical}" >&2; return 1;
    }
    rolling_wait_ready "${logical}" || return 1
    rolling_matches_image "${logical}" "$(rolling_read "${prefix}_IMAGE_TAG" "${DEPLOY_ENV}")" || return 1
    rolling_check_callers "${logical}" || return 1
  else
    if ! rolling_wait_ready "${logical}-a" || ! rolling_wait_ready "${logical}-b"; then
      echo "A/B 두 인스턴스가 모두 준비되어야 배포 가능: ${logical}" >&2
      return 1
    fi
    for slot in a b; do
      key="${prefix}_$(printf '%s' "${slot}" | tr '[:lower:]' '[:upper:]')_IMAGE_TAG"
      previous="$(rolling_read "${key}" "${DEPLOY_ENV}")"
      previous="${previous:-$(rolling_read "${prefix}_IMAGE_TAG" "${DEPLOY_ENV}")}"
      rolling_matches_image "${logical}-${slot}" "${previous}" || return 1
    done
  fi
  rolling_write "${candidate_env_file}" "${prefix}_A_IMAGE_TAG" "${desired}" || return 1
  rolling_write "${candidate_env_file}" "${prefix}_B_IMAGE_TAG" "${desired}" || return 1
  rolling_compose "${candidate_env_file}" config --quiet || return 1
  rolling_compose "${candidate_env_file}" pull "${logical}-a" "${logical}-b" || return 1

  if [[ -n "${legacy}" ]]; then
    rolling_migrate_single "${logical}" "${desired}" "${prefix}" "${candidate_env_file}" "${journal}" "${base_url}" || return 1
  else
    for slot in a b; do
      target="${logical}-${slot}"
      peer="${logical}-b"
      [[ "${slot}" != b ]] || peer="${logical}-a"
      key="${prefix}_$(printf '%s' "${slot}" | tr '[:lower:]' '[:upper:]')_IMAGE_TAG"
      previous="$(rolling_read "${key}" "${DEPLOY_ENV}")"
      previous="${previous:-$(rolling_read "${prefix}_IMAGE_TAG" "${DEPLOY_ENV}")}"
      [[ "${previous}" =~ ^[0-9a-f]{40}$ ]] || return 1
      rolling_wait_ready discovery-service && rolling_wait_ready "${peer}" || return 1
      printf 'service=%s\ntarget=%s\nprevious=%s\ndesired=%s\nstage=prepared\n' \
        "${logical}" "${target}" "${previous}" "${desired}" >"${journal}" || return 1
      if ! rolling_drain "${logical}" "${target}"; then
        rolling_admit "${logical}" "${target}" || return 1
        rm -f "${journal}" "${candidate_env_file}"
        return 1
      fi
      rolling_write "${journal}" stage replacing || return 1
      failed=false
      if rolling_start "${candidate_env_file}" "${target}" "${desired}"; then
        rolling_admit "${logical}" "${target}" || failed=true
      else
        failed=true
      fi
      # 외부 공개 경로의 회귀 확인 후에만 다음 자리로 진행.
      if [[ "${failed}" == false ]]; then "${SMOKE_SCRIPT}" "${base_url}" || failed=true; fi
      if [[ "${failed}" == true ]]; then
        echo "슬롯 교체 실패, 다른 슬롯 유지: ${target}" >&2
        # 준비 검사 실패와 실행 실패의 구분. 이미 요청을 받는 새 실행의 제외 확인 후 복구.
        container="$(rolling_container "${target}")" || return 1
        [[ "${container}" != *$'\n'* ]] || return 1
        if [[ -n "${container}" ]]; then
          container_status="$(docker inspect --format '{{.State.Status}}' "${container}")" || return 1
          case "${container_status}" in
            running) rolling_drain "${logical}" "${target}" || return 1 ;;
            created|exited|dead) ;; # 실행되지 않았거나 종료된 컨테이너의 직접 복구.
            *)
              echo "복구 전 실행 상태 확인 필요: ${target} (${container_status}). 현재 실행·기록 유지" >&2
              return 1
              ;;
          esac
        fi
        rolling_write "${candidate_env_file}" "${key}" "${previous}" || return 1
        rolling_start "${candidate_env_file}" "${target}" "${previous}" && rolling_admit "${logical}" "${target}" || return 1
        rm -f "${journal}" "${candidate_env_file}"
        return 1
      fi
      rolling_write "${DEPLOY_ENV}" "${key}" "${desired}" || return 1
      rolling_write "${journal}" stage verified || return 1
      # 검증과 이미지 기록까지 끝난 자리의 미완료 표시 해제. 다음 자리의 사전 검사 실패와 구분.
      rm -f "${journal}" || return 1
    done
  fi
  rolling_wait_ready "${logical}-a" && rolling_wait_ready "${logical}-b" || return 1
  rolling_write "${DEPLOY_ENV}" "${prefix}_IMAGE_TAG" "${desired}" || return 1
  rm -f "${journal}" "${candidate_env_file}"
  echo "A/B 배포 완료: ${logical} (${desired})"
}

# 최초 전환 전용 순서: 단일+A → A → A+B. 어느 단계에서든 실패하면 현재 실행·기록 유지.
# 평상시 슬롯 교체와 달리, 단일 구성 전체로 자동 복귀하는 기능은 제공하지 않음.
rolling_migrate_single() {
  local logical="$1" desired="$2" prefix="$3" candidate_env_file="$4" journal="$5" base_url="$6"
  local slot target key previous
  previous="$(rolling_read "${prefix}_IMAGE_TAG" "${DEPLOY_ENV}")" || return 1
  for slot in a b; do
    target="${logical}-${slot}"
    key="${prefix}_$(printf '%s' "${slot}" | tr '[:lower:]' '[:upper:]')_IMAGE_TAG"
    rolling_wait_ready discovery-service || return 1
    if [[ "${slot}" == b ]]; then rolling_wait_ready "${logical}-a" || return 1; fi
    printf 'service=%s\ntarget=%s\nprevious=%s\ndesired=%s\nstage=prepared\n' \
      "${logical}" "${target}" "${previous}" "${desired}" >"${journal}" || return 1
    rolling_write "${journal}" stage replacing || return 1
    if ! rolling_start "${candidate_env_file}" "${target}" "${desired}" \
      || ! rolling_admit "${logical}" "${target}" \
      || ! "${SMOKE_SCRIPT}" "${base_url}"; then
      echo "첫 전환 실패. 현재 실행과 진행 기록 확인 필요: ${journal}" >&2
      return 1
    fi
    if [[ "${slot}" == a ]]; then
      # 새 A의 외부 응답까지 확인한 뒤 기존 단일 실행 종료. 세 번째 실행 생성 방지.
      rolling_write "${journal}" stage retiring-legacy || return 1
      rolling_drain "${logical}" "${logical}" || return 1
      rolling_compose "${DEPLOY_ENV}" stop "${logical}" || return 1
      rolling_compose "${DEPLOY_ENV}" rm -f "${logical}" || return 1
    fi
    rolling_write "${DEPLOY_ENV}" "${key}" "${desired}" || return 1
    rolling_write "${journal}" stage verified || return 1
  done
}

rolling_compose() {
  local env_file="$1"
  shift
  DEPLOY_ENV_FILE="${env_file}" SECRET_ENV_FILE="${SECRET_ENV}" "${COMPOSE_SCRIPT}" "$@"
}

rolling_read() {
  awk -F= -v key="$1" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$2"
}

# 동일 Directory의 후보 파일 교체로 부분 기록 노출 방지.
rolling_write() {
  local file="$1" key="$2" value="$3" next
  next="$(mktemp "${file}.XXXXXX")" || return 1
  if ! awk -F= -v key="${key}" -v value="${value}" '
    $1 == key {print key "=" value; found=1; next}
    {print}
    END {if (!found) print key "=" value}
  ' "${file}" >"${next}"; then
    rm -f "${next}"
    return 1
  fi
  mv -f "${next}" "${file}"
}

rolling_container() {
  docker ps --all --quiet \
    --filter label=com.docker.compose.project=omagotchi \
    --filter "label=com.docker.compose.service=$1"
}

rolling_ready() {
  local target="$1" container path url http_status port=8080
  local paths=(/actuator/health/readiness /actuator/health)
  container="$(rolling_container "${target}")" || return 1
  [[ -n "${container}" && "${container}" != *$'\n'* ]] || {
    echo "준비 검사 대상 컨테이너 식별 실패: ${target}" >&2; return 1;
  }
  [[ "$(docker inspect --format '{{.State.Running}}' "${container}")" == true ]] || {
    echo "준비 검사 대상의 실행 상태 확인 실패: ${target}" >&2; return 1;
  }
  [[ "${target}" != prediction-service* ]] || paths=(/health)
  if [[ "${target}" == discovery-service ]]; then port=8761; paths=(/actuator/health); fi
  # 요청 수락 준비와 기존 의존성 Health 모두 확인. 준비 직후의 Eureka 상태 반영 대기 포함.
  for path in "${paths[@]}"; do
    url="http://127.0.0.1:${port}${path}"
    if ! http_status="$(docker exec "${container}" curl --fail --silent --show-error --max-time 5 \
      --output /dev/null --write-out '%{http_code}' "${url}")"; then
      echo "준비 검사 실패: ${target} (${url}, HTTP ${http_status:-응답 없음})" >&2
      return 1
    fi
  done
  case "${target}" in
    gateway-service*|identity-service*|learning-service*|rule-engine-*)
      # 현재 실행의 실제 등록 확인. 초기 Health 응답만으로 배포 준비 완료 판단 금지.
      rolling_registry "${target}" | jq -e '
        .instanceId as $id | [.services[][]] | index($id) != null
      ' >/dev/null || {
        echo "준비 검사 실패: ${target} (/actuator/registry의 현재 실행 UP 등록 미확인)" >&2
        return 1
      }
      ;;
  esac
}

rolling_registry() {
  local target="$1" container
  container="$(rolling_container "${target}")" || return 1
  [[ -n "${container}" && "${container}" != *$'\n'* ]] || return 1
  docker exec "${container}" curl --fail --silent --show-error --max-time 5 \
    http://127.0.0.1:8080/actuator/registry
}

# 일시적인 Health·Eureka 조회 실패의 재확인. 제한 시간 내 복구되지 않으면 마지막 실패 내용 출력.
rolling_wait_ready() {
  local target="$1" deadline=$((SECONDS + 90)) last_error=""
  while ((SECONDS < deadline)); do
    if last_error="$(rolling_ready "${target}" 2>&1)"; then return 0; fi
    sleep 2
  done
  echo "준비·의존성 확인 시간 초과: ${target}" >&2
  printf '%s\n' "${last_error}" >&2
  return 1
}

# 상태 파일과 실제 실행 이미지가 다르면 추정한 버전으로 교체·복구 금지.
rolling_matches_image() {
  local target="$1" revision="$2" container image
  [[ "${revision}" =~ ^[0-9a-f]{40}$ ]] || return 1
  container="$(rolling_container "${target}")" || return 1
  image="$(docker inspect --format '{{.Config.Image}}' "${container}")" || return 1
  [[ "${image##*:}" == "${revision}" ]] || {
    echo "배포 기록과 실행 이미지 불일치: ${target}" >&2
    return 1
  }
}

rolling_status() {
  local target="$1" status="$2" container response
  container="$(rolling_container "${target}")" || return 1
  docker exec "${container}" curl --fail --silent --show-error --max-time 5 \
    -H 'Content-Type: application/json' -d "{\"status\":\"${status}\"}" \
    http://127.0.0.1:8080/actuator/serviceregistry || return 1
  response="$(docker exec "${container}" curl --fail --silent --show-error --max-time 5 \
    http://127.0.0.1:8080/actuator/serviceregistry)" || return 1
  if [[ "${status}" == OUT_OF_SERVICE ]]; then
    jq -e '.status == "OUT_OF_SERVICE" and .overriddenStatus == "OUT_OF_SERVICE"' <<<"${response}" >/dev/null
  else
    jq -e '.overriddenStatus == "UNKNOWN"' <<<"${response}" >/dev/null
  fi
}

# 실행 중인 실제 호출자 모두에서 대상 반영 확인. 고정 sleep으로 Cache 갱신 추정 금지.
rolling_wait_clients() {
  local application="$1" instance="$2" present="$3" deadline=$((SECONDS + 90))
  local containers container target snapshot complete
  containers="$(docker ps --quiet --filter label=com.docker.compose.project=omagotchi)" || return 1
  [[ -n "${containers}" ]] || return 1
  while ((SECONDS < deadline)); do
    complete=true
    while read -r container; do
      if ! target="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "${container}")"; then
        complete=false
        continue
      fi
      case "${target}" in
        gateway-service*|frontend*|learning-service*|rule-engine-a|rule-engine-b) ;;
        *) continue ;;
      esac
      # 일시적인 조회 실패는 반영 미완료로 처리, 기존 제한 시간 안에서 재확인.
      if ! snapshot="$(rolling_registry "${target}")"; then
        complete=false
        continue
      fi
      if ! jq -e --arg app "${application}" --arg id "${instance}" --argjson present "${present}" '
        (.services[$app] // []) as $ids |
        ($ids | length) > 0 and (($ids | index($id) != null) == $present)
      ' <<<"${snapshot}" >/dev/null; then
        complete=false
      fi
    done <<<"${containers}"
    [[ "${complete}" != true ]] || return 0
    sleep 2
  done
  echo "호출자 Registry 반영 시간 초과: ${application} ${instance}" >&2
  return 1
}

# Git 제외 Directory 안의 대상 파일 생성. 첫 전환 전의 단일 이름도 지원.
rolling_initialize_routes() {
  local directory="${INFRA_DIR}/nginx/conf.d/runtime" group logical target
  mkdir -p "${directory}" || return 1
  chmod 755 "${directory}" || return 1
  for group in frontend gateway prediction; do
    [[ ! -f "${directory}/${group}.servers" ]] || continue
    logical="${group}-service"
    [[ "${group}" != frontend ]] || logical=frontend
    : >"${directory}/${group}.servers" || return 1
    for target in "${logical}" "${logical}-a" "${logical}-b"; do
      if rolling_ready "${target}" 2>/dev/null; then
        printf 'server %s:8080 resolve;\n' "${target}" >>"${directory}/${group}.servers" || return 1
      fi
    done
    if [[ ! -s "${directory}/${group}.servers" ]]; then
      printf 'server 127.0.0.1:9 down;\n' >"${directory}/${group}.servers" || return 1
    fi
  done
  {
    for group in frontend gateway prediction; do
      printf 'upstream %s_upstream {\n zone %s_upstream 64k;\n' "${group}" "${group}"
      cat "${directory}/${group}.servers" || return 1
      printf '}\n'
    done
  } >"${directory}/upstreams.conf" || return 1
  chmod 644 "${directory}"/*.servers "${directory}/upstreams.conf"
}

# 후보 전체 설정 검사 → 교체 → Reload → 이전 Worker 종료 확인.
# 기존 Worker의 장시간 요청이 남으면 앱을 종료하지 않고 실패 반환.
rolling_route() {
  local group="$1" target="$2" include="$3" directory="${INFRA_DIR}/nginx/conf.d/runtime"
  local container upstream_group old_workers worker_pid active_workers complete deadline=$((SECONDS + 150))
  container="$(rolling_container nginx)" || return 1
  [[ -n "${container}" ]] || return 1
  awk -v target="${target}:8080" '$2 != target && $2 != "127.0.0.1:9"' \
    "${directory}/${group}.servers" >"${directory}/${group}.next" || return 1
  if [[ "${include}" == true ]]; then
    printf 'server %s:8080 resolve;\n' "${target}" >>"${directory}/${group}.next" || return 1
  fi
  [[ -s "${directory}/${group}.next" ]] || { echo "마지막 정상 Upstream 제외 거부" >&2; return 1; }
  {
    for upstream_group in frontend gateway prediction; do
      printf 'upstream %s_upstream {\n zone %s_upstream 64k;\n' "${upstream_group}" "${upstream_group}"
      if [[ "${upstream_group}" == "${group}" ]]; then
        cat "${directory}/${group}.next" || return 1
      else
        cat "${directory}/${upstream_group}.servers" || return 1
      fi
      printf '}\n'
    done
  } >"${directory}/upstreams.build" || return 1
  mv -f "${directory}/upstreams.build" "${directory}/upstreams.next" || return 1
  sed 's@runtime/upstreams.conf@runtime/upstreams.next@' "${INFRA_DIR}/nginx/conf.d/default.conf" >"${directory}/default.build" || return 1
  mv -f "${directory}/default.build" "${directory}/default.next" || return 1
  printf 'events {}\nhttp { include /etc/nginx/mime.types; include /etc/nginx/conf.d/runtime/default.next; }\n' \
    >"${directory}/nginx.build" || return 1
  mv -f "${directory}/nginx.build" "${directory}/nginx.next" || return 1
  chmod 644 "${directory}"/*.next || return 1
  docker exec "${container}" nginx -t -c /etc/nginx/conf.d/runtime/nginx.next || return 1
  old_workers="$(docker exec "${container}" sh -c "ps -o pid,args | awk '/nginx: worker process/ && !/awk/ {print \$1}'")" || return 1
  [[ -n "${old_workers}" ]] || return 1
  # 파일 교체·Reload 명령 실패에 대비한 직전 분배 목록과 읽기 권한 보존.
  cp -p "${directory}/upstreams.conf" "${directory}/upstreams.previous" || return 1
  cp -p "${directory}/${group}.servers" "${directory}/${group}.previous" || return 1
  if ! mv -f "${directory}/upstreams.next" "${directory}/upstreams.conf" \
    || ! mv -f "${directory}/${group}.next" "${directory}/${group}.servers" \
    || ! docker exec "${container}" nginx -s reload; then
    mv -f "${directory}/upstreams.previous" "${directory}/upstreams.conf" || echo "Nginx 전체 분배 목록 복구 실패" >&2
    mv -f "${directory}/${group}.previous" "${directory}/${group}.servers" || echo "Nginx 서비스 분배 목록 복구 실패: ${group}" >&2
    echo "Nginx 분배 목록 적용 실패. 대상 앱 유지, 파일·실행 설정 확인 필요: ${target}" >&2
    return 1
  fi
  rm -f "${directory}/upstreams.previous" "${directory}/${group}.previous" || return 1
  while ((SECONDS < deadline)); do
    active_workers="$(docker exec "${container}" sh -c "ps -o pid,args | awk '/nginx: worker process/ && !/awk/ {print \$1}'")" || return 1
    [[ -n "${active_workers}" ]] || return 1
    complete=true
    while read -r worker_pid; do
      if grep -Fxq "${worker_pid}" <<<"${active_workers}"; then complete=false; fi
    done <<<"${old_workers}"
    [[ "${complete}" != true ]] || return 0
    sleep 2
  done
  echo "Nginx 이전 Worker 종료 시간 초과. 대상 앱 유지: ${target}" >&2
  return 1
}

rolling_drain() {
  local logical="$1" target="$2" instance
  case "${logical}" in
    frontend) rolling_route frontend "${target}" false ;;
    gateway-service) rolling_route gateway "${target}" false ;;
    prediction-service) rolling_route prediction "${target}" false ;;
    identity-service|learning-service|rule-service)
      instance="$(rolling_registry "${target}" | jq -er '.instanceId')" || return 1
      rolling_status "${target}" OUT_OF_SERVICE || return 1
      rolling_wait_clients "$(printf '%s' "${logical}" | tr '[:lower:]' '[:upper:]')" "${instance}" false
      ;;
    *) return 1 ;;
  esac
}

rolling_admit() {
  local logical="$1" target="$2" instance
  case "${logical}" in
    frontend) rolling_ready "${target}" && rolling_route frontend "${target}" true ;;
    gateway-service) rolling_ready "${target}" && rolling_route gateway "${target}" true ;;
    prediction-service) rolling_ready "${target}" && rolling_route prediction "${target}" true ;;
    identity-service|learning-service|rule-service)
      # 제외 상태에서는 전체 Health가 DOWN일 수 있으므로 강제 상태부터 해제.
      rolling_status "${target}" CANCEL_OVERRIDE || return 1
      rolling_wait_ready "${target}" || return 1
      instance="$(rolling_registry "${target}" | jq -er '.instanceId')" || return 1
      rolling_wait_clients "$(printf '%s' "${logical}" | tr '[:lower:]' '[:upper:]')" "${instance}" true
      ;;
    *) return 1 ;;
  esac
}

# 한 슬롯의 재생성·이미지·준비 확인. 요청 대상 복귀는 rolling_admit의 담당.
# 같은 SHA의 설정 변경도 재생성 대상.
rolling_start() {
  local env_file="$1" target="$2" expected="$3"
  rolling_compose "${env_file}" up -d --no-deps --force-recreate --pull never \
    --wait --wait-timeout 300 "${target}" || return 1
  rolling_matches_image "${target}" "${expected}" || return 1
  rolling_wait_ready "${target}"
}

# 첫 전환에서 단일 DNS 이름을 없애기 전, 실제 호출자의 새 주소 적용 확인.
rolling_check_callers() {
  local logical="$1" target container expected count=0 targets=()
  case "${logical}" in
    learning-service)
      targets=(rule-engine-a rule-engine-b)
      expected='LEARNING_BASE_URL=lb://learning-service'
      ;;
    prediction-service)
      targets=(learning-service learning-service-a learning-service-b)
      expected='PREDICTION_SERVICE_BASE_URL=http://nginx:8081'
      ;;
    *) return 0 ;;
  esac
  for target in "${targets[@]}"; do
    container="$(rolling_container "${target}")" || return 1
    [[ -n "${container}" ]] || continue
    if [[ "$(docker inspect --format "{{range .Config.Env}}{{if eq . \"${expected}\"}}true{{end}}{{end}}" "${container}")" != true ]]; then
      echo "호출 주소 선행 전환 필요: ${target} → ${logical}. 기존 단일 실행 유지" >&2
      return 1
    fi
    count=$((count + 1))
  done
  ((count > 0)) || { echo "호출자 실행 확인 실패: ${logical}" >&2; return 1; }
}
