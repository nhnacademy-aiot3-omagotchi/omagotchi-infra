#!/usr/bin/env bash
set -euo pipefail

# 실제 Adapter·Compose의 선택적 재생성 검증. 제품 대신 격리된 경량 Container 사용.
# 학교 접속·운영 Volume·알림 전송 제외.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
COMPOSE=(docker compose --project-name "omagotchi-recreate-test-$$" --file "${TEST_TMP_DIR}/compose.json")

cleanup() {
  "${COMPOSE[@]}" down --volumes >/dev/null 2>&1 || true
  rm -rf -- "${TEST_TMP_DIR}"
}
trap cleanup EXIT
mkdir "${TEST_TMP_DIR}/scripts"
cp "${INFRA_DIR}/scripts/observability-compose.sh" "${TEST_TMP_DIR}/scripts/"
cp -R "${INFRA_DIR}/observability" "${TEST_TMP_DIR}/observability"
cp "${INFRA_DIR}/.env.prod.example" "${TEST_TMP_DIR}/prod.env"

# 실제 설정의 Label·환경변수 유지, 외부 연결·제품별 시작 절차만 테스트용으로 대체.
render_fixture() {
  SECRET_ENV_FILE="${TEST_TMP_DIR}/prod.env" bash "${TEST_TMP_DIR}/scripts/observability-compose.sh" \
    --profile alerts --profile metrics --profile tracing config --format json |
    jq '{services: (.services | with_entries(.value = {
      image: "nginx:1.30.3-alpine", entrypoint: ["sleep", "360"], command: [],
      network_mode: "none", read_only: true, mem_limit: "16m", cap_drop: ["ALL"],
      init: true, stop_grace_period: "1s",
      labels: .value.labels, environment: (.value.environment // {}), volumes: ["state:/state"]
    })), volumes: {state: {}}}' >"${TEST_TMP_DIR}/compose.json"
}

container_ids() {
  "${COMPOSE[@]}" ps --format json | jq -sS 'map({key: .Service, value: .ID}) | from_entries'
}

render_fixture
"${COMPOSE[@]}" up -d --wait
initial_ids="$(container_ids)"
jq -e 'length == 6' <<<"${initial_ids}" >/dev/null
"${COMPOSE[@]}" exec -T filebeat sh -c 'printf retained >/state/sentinel'

# 같은 설정의 재배포에서 Container 유지.
render_fixture
"${COMPOSE[@]}" up -d --wait
[[ "$(container_ids)" == "${initial_ids}" ]]

# 연결된 파일 내용만 변경한 경우에도 해당 도구만 재생성, 기존 Volume 재사용.
printf '\n# 재생성 검증용 설정 변경\n' >>"${TEST_TMP_DIR}/observability/filebeat/filebeat.yml"
render_fixture
"${COMPOSE[@]}" up -d --wait
changed_ids="$(container_ids)"
jq -en --argjson before "${initial_ids}" --argjson after "${changed_ids}" '
  $before | keys | all(.[];
    if . == "filebeat" then $before[.] != $after[.] else $before[.] == $after[.] end
  )' >/dev/null
[[ "$("${COMPOSE[@]}" exec -T filebeat cat /state/sentinel)" == retained ]]

# Secret 교체는 기존 Compose 환경변수 비교로 반영, 공개 설정 Label에는 영향 없음.
config_labels="$(jq -cS '.services | map_values(.labels)' "${TEST_TMP_DIR}/compose.json")"
sed 's/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=fixture-rotation/' \
  "${TEST_TMP_DIR}/prod.env" >"${TEST_TMP_DIR}/rotated.env"
mv "${TEST_TMP_DIR}/rotated.env" "${TEST_TMP_DIR}/prod.env"
render_fixture
[[ "$(jq -cS '.services | map_values(.labels)' "${TEST_TMP_DIR}/compose.json")" == "${config_labels}" ]]
"${COMPOSE[@]}" up -d --wait
jq -en --argjson before "${changed_ids}" --argjson after "$(container_ids)" '
  $before | keys | all(.[];
    if . == "grafana" then $before[.] != $after[.] else $before[.] == $after[.] end
  )' >/dev/null

echo '관측 도구의 변경 없는 재배포·설정별 재생성·Volume 보존·Secret 교체 검증 통과.'
