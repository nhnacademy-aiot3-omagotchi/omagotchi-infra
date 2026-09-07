#!/usr/bin/env bash
set -euo pipefail

# 실제 제품의 설정 해석 검증. 환경변수의 업무 값·학교 자원 상태에 대한 단정 제외.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
FIXTURE_NAME="omagotchi-autodiscover-test-$$"
FILEBEAT_NAME="${FIXTURE_NAME}-filebeat"
COMPOSE=(docker compose
  --project-name "omagotchi-observability-config-test-$$"
  --env-file "${INFRA_DIR}/.env.prod.example"
  --file "${INFRA_DIR}/observability/compose.yaml")

cleanup() {
  # 이 테스트에서 만든 프로젝트의 임시 Volume·Network만 정리.
  docker rm --force "${FILEBEAT_NAME}" "${FIXTURE_NAME}" >/dev/null 2>&1 || true
  "${COMPOSE[@]}" down --volumes >/dev/null 2>&1 || true
  rm -rf -- "${TEST_TMP_DIR}"
}
trap cleanup EXIT

"${COMPOSE[@]}" config --quiet
"${COMPOSE[@]}" run --rm --no-deps filebeat \
  filebeat test config --strict.perms=false -e -E logging.level=error \
  -E 'output.elasticsearch.hosts=["http://127.0.0.1:1"]'

# 수집 입력이 없는 초기화 설정의 해석 검증. 실제 setup은 로컬 종단 검증·운영 최초 적용에서 수행.
"${COMPOSE[@]}" run --rm --no-deps --entrypoint filebeat filebeat-setup \
  export config --strict.perms=false -e -E logging.level=error >/dev/null

jq -e . "${INFRA_DIR}/observability/elasticsearch/index-template.json" >/dev/null
jq -e . "${INFRA_DIR}/observability/elasticsearch/lifecycle-policy.json" >/dev/null

# Compose의 부모·하위 Label 공존 조건에서 실제 Filebeat 입력 생성 확인.
# 테스트 프로젝트만 선택, 실제 Docker 로그 경로·Elasticsearch 출력은 사용하지 않음.
sed -e "s/: omagotchi$/: ${FIXTURE_NAME}/" \
  -e 's|/var/lib/docker/containers/|/nonexistent-fixture/|' \
  "${INFRA_DIR}/observability/filebeat/filebeat.yml" >"${TEST_TMP_DIR}/filebeat.yml"
chmod 644 "${TEST_TMP_DIR}/filebeat.yml"
fixture_id="$(docker run --detach --name "${FIXTURE_NAME}" \
  --network none --read-only --cap-drop ALL --memory 16m \
  --label "com.docker.compose.project=${FIXTURE_NAME}" \
  --label 'com.docker.compose.project.working_dir=/fixture' \
  --label 'com.docker.compose.project.config_files=/fixture/compose.yaml' \
  --label 'co.elastic.logs/enabled=true' \
  --entrypoint sleep nginx:1.30.3-alpine 60)"

"${COMPOSE[@]}" run --detach --no-deps --name "${FILEBEAT_NAME}" \
  --volume "${TEST_TMP_DIR}/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro" \
  filebeat filebeat --strict.perms=false -e \
  -E output.elasticsearch.enabled=false -E output.console.enabled=true \
  -E logging.metrics.enabled=false >/dev/null

input_started=false
for _ in {1..20}; do
  docker logs "${FILEBEAT_NAME}" >"${TEST_TMP_DIR}/filebeat.log" 2>&1
  if jq -se --arg id "container-${fixture_id}" \
    'any(.[]; .id == $id and .message == "Input '\''filestream'\'' starting")' \
    "${TEST_TMP_DIR}/filebeat.log" >/dev/null; then
    input_started=true
    break
  fi
  sleep 0.5
done
if [[ "${input_started}" != true ]]; then
  echo 'Compose Label이 일치하는 Container의 Filebeat 입력 생성 실패' >&2
  tail -n 15 "${TEST_TMP_DIR}/filebeat.log" >&2
  exit 1
fi

echo '관측 설정 해석·실제 Filebeat 입력 생성 통과. Elasticsearch 쓰기·Telegram 전송 없음.'
