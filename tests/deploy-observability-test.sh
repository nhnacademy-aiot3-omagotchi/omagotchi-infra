#!/usr/bin/env bash
set -euo pipefail

# 실제 배포 Script와 외부 Compose 경계만 사용. 학교 접속·Container 변경·알림 전송 없음.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP_DIR}"' EXIT
mkdir -p "${TEST_TMP_DIR}/scripts" "${TEST_TMP_DIR}/bin"
cp "${SCRIPT_DIR}/../scripts/deploy-observability.sh" "${TEST_TMP_DIR}/scripts/"

cat >"${TEST_TMP_DIR}/scripts/observability-compose.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MODE_TEST_EVENTS}"
[[ "$*" == '--profile alerts --profile metrics --profile tracing '* ]]
shift 6
case "$1" in
  config)
    token=fixture-token
    [[ "${MODE_TEST_SCENARIO}" != missing-secret ]] || token=""
    printf '{"services":{"elastalert":{"environment":{"OPS_TELEGRAM_BOT_TOKEN":"%s","OPS_TELEGRAM_CHAT_ID":"-100123"}},"grafana":{"environment":{"GF_SECURITY_ADMIN_PASSWORD":"fixture-password"}}}}\n' "$token"
    ;;
  pull) [[ "${MODE_TEST_SCENARIO}" != pull-failure ]] ;;
  run)
    [[ " $* " != *" setup "* && " $* " != *"-setup "* ]]
    if [[ "$*" == *"elastalert prepare" && "${MODE_TEST_SCENARIO}" == prepare-failure ]]; then exit 1; fi
    if [[ "$*" == *"filebeat test output"* && "${MODE_TEST_SCENARIO}" == output-failure ]]; then exit 1; fi
    ;;
  up)
    for required in --no-deps --force-recreate --wait filebeat elastalert prometheus grafana otel-collector tempo; do
      [[ " $* " == *" ${required} "* ]]
    done
    [[ "$*" != *setup* && "$*" != *--remove-orphans* ]]
    [[ "${MODE_TEST_SCENARIO}" != start-failure ]]
    ;;
  exec)
    [[ "$*" == 'exec -T --interactive=false prometheus wget '* ]]
    # 첫 연결 실패 이후의 재시도 성공.
    if [[ "${MODE_TEST_SCENARIO}" == retry && ! -f "${MODE_TEST_EVENTS}.retried" ]]; then
      touch "${MODE_TEST_EVENTS}.retried"
      exit 1
    fi
    ;;
  ps)
    count=6
    [[ "${MODE_TEST_SCENARIO}" != missing-container ]] || count=5
    for ((i=0; i<count; i++)); do
      printf 'fixture-container-%s\n' "$i"
    done
    ;;
  *) exit 1 ;;
esac
EOF
cat >"${TEST_TMP_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == inspect ]]
shift 3
for container_id in "$@"; do
  state=running
  restarts=0
  if [[ "$container_id" == fixture-container-0 ]]; then
    [[ "${MODE_TEST_SCENARIO}" != restarting ]] || state=restarting
    [[ "${MODE_TEST_SCENARIO}" != restarted ]] || restarts=1
  fi
  printf '{"State":"%s","Restarts":%s}\n' "$state" "$restarts"
done
EOF
cat >"${TEST_TMP_DIR}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TEST_TMP_DIR}/scripts/observability-compose.sh" "${TEST_TMP_DIR}/bin/sleep" "${TEST_TMP_DIR}/bin/docker"

for scenario in success retry missing-secret pull-failure prepare-failure output-failure start-failure missing-container restarting restarted; do
  events="${TEST_TMP_DIR}/${scenario}.events"
  output="${TEST_TMP_DIR}/${scenario}.output"
  : >"${events}"
  status=0
  MODE_TEST_SCENARIO="${scenario}" MODE_TEST_EVENTS="${events}" \
    PATH="${TEST_TMP_DIR}/bin:${PATH}" bash "${TEST_TMP_DIR}/scripts/deploy-observability.sh" \
    >"${output}" 2>&1 || status=$?
  case "${scenario}" in
    success | retry)
      [[ "$status" == 0 ]] || { cat "${output}"; exit 1; }
      for endpoint in '127.0.0.1:9090/-/ready' 'grafana.:3000/api/health' 'otel-collector.:13133/' 'tempo.:3200/ready'; do
        grep -Fq "$endpoint" "${events}"
      done
      grep -Fq 'filebeat test output' "${events}"
      grep -Fq 'elastalert prepare' "${events}"
      grep -Fq 'HTTP 준비 확인 시작: http://grafana.:3000/api/health' "${output}"
      grep -Fq 'HTTP 준비 확인 완료: http://grafana.:3000/api/health' "${output}"
      ;;
    *)
      [[ "$status" != 0 ]] || { echo "실패 조건의 성공 처리: ${scenario}" >&2; exit 1; }
      if grep -q '관측성 배포 완료' "${output}"; then exit 1; fi
      ;;
  esac
  # 준비 실패 시 실행 중인 관측 도구의 재생성 금지.
  case "${scenario}" in
    missing-secret | pull-failure | prepare-failure | output-failure)
      if grep -q ' up ' "${events}"; then exit 1; fi
      ;;
  esac
  # Config 검증 결과의 인증 정보 출력 금지.
  if grep -Eq 'fixture-token|fixture-password' "${output}"; then exit 1; fi
done

echo "관측성 자동배포의 기동·준비 확인·실패 전파 검증 통과."
