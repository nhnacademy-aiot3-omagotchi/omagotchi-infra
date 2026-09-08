#!/usr/bin/env bash
set +x
set -euo pipefail

# 전체 Infra 배포의 관측성 단계. Revision 확인·배포 Lock은 deploy-infra.sh의 책임.
# 기존 저장소 재사용·알림 저장소 전체 부재 시 최초 생성. Volume·업무 Container 유지.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICES=(filebeat elastalert prometheus grafana otel-collector tempo)

compose() {
  "${SCRIPT_DIR}/observability-compose.sh" \
    --profile alerts --profile metrics --profile tracing "$@" </dev/null
}

# 같은 Container의 배포 전후 비교용 상태. 환경변수·인증 정보의 조회 제외.
container_states() {
  local ids
  local container_ids=()
  local container_id
  ids="$(compose ps --all --quiet "${SERVICES[@]}")" || return 1
  while IFS= read -r container_id; do
    [[ -z "${container_id}" ]] || container_ids+=("${container_id}")
  done <<<"${ids}"
  if ((${#container_ids[@]} == 0)); then
    printf '[]\n'
    return
  fi
  docker inspect --format '{"Id":"{{.Id}}","State":"{{.State.Status}}","Restarts":{{.RestartCount}}}' \
    "${container_ids[@]}" | jq -s .
}

# 기존 Secret의 검증만 수행. Compose 원문·인증값의 로그 출력 제외.
if ! compose config --format json 2>/dev/null | jq -e '
  [.services.elastalert.environment.OPS_TELEGRAM_BOT_TOKEN,
   .services.elastalert.environment.OPS_TELEGRAM_CHAT_ID,
   .services.grafana.environment.GF_SECURITY_ADMIN_PASSWORD]
  | all(type == "string" and length > 0)' >/dev/null; then
  echo "관측성 설정 검증 실패. prod.env의 Elasticsearch·Telegram·Grafana 필수 설정 확인 필요." >&2
  exit 1
fi

# 다운로드·접속·초기화 상태를 먼저 확인, 준비 실패 시 실행 중인 도구 유지.
compose pull "${SERVICES[@]}"
if ! compose run --rm -T --no-deps elastalert prepare; then
  echo "관측 저장소 준비 실패. 로그 저장소·알림 상태의 기존 자원·부분 생성 여부 확인 필요." >&2
  exit 1
fi
if ! compose run --rm -T --no-deps filebeat \
  filebeat test output --strict.perms=false -e -E logging.level=error \
  -E output.elasticsearch.timeout=5s >/dev/null 2>&1; then
  echo "Filebeat의 Elasticsearch 연결 확인 실패. 기존 수집기 유지." >&2
  exit 1
fi

# 공개 설정의 내용 해시를 Label로 반영, 이미지·환경변수와 함께 Compose에서 변경 판단.
# 변경 없는 Runtime·기존 Volume 유지, 최초 기동과 변경 대상만 생성·재생성.
previous_states="$(container_states)"
compose up -d --no-deps --wait --wait-timeout 180 "${SERVICES[@]}"

# Running 상태와 HTTP 준비 상태의 구분. 기존 Prometheus 이미지의 wget 재사용.
# Collector·Tempo 확인을 위한 Host Port·진단 Container 추가 없음.
# 끝의 점은 DNS 검색 도메인을 적용하지 않는 절대 이름. 서버의 search . 설정에서
# BusyBox wget이 짧은 이름을 해석하지 못하는 경우에도 Docker DNS로 직접 조회.
deadline=$((SECONDS + 180))
for endpoint in \
  http://127.0.0.1:9090/-/ready \
  http://grafana.:3000/api/health \
  http://otel-collector.:13133/ \
  http://tempo.:3200/ready; do
  echo "관측 도구의 HTTP 준비 확인 시작: ${endpoint}"
  ready=false
  probe_error=""
  while ((SECONDS < deadline)); do
    if probe_error="$(compose exec -T --interactive=false prometheus \
      wget -q -T 5 -O /dev/null "${endpoint}" 2>&1)"; then
      ready=true
      break
    fi
    sleep 2
  done
  if [[ "${ready}" != true ]]; then
    echo "관측 도구의 HTTP 준비 확인 실패: ${endpoint}" >&2
    # 응답·인증값 원문 대신 점검 실패의 종류만 남김.
    case "${probe_error}" in
      *'bad address'*) echo '원인: 점검 컨테이너의 DNS 이름 조회 실패.' >&2 ;;
      *'Connection refused'*) echo '원인: 대상 HTTP 연결 거절.' >&2 ;;
      *'timed out'*) echo '원인: 대상 HTTP 응답 시간 초과.' >&2 ;;
      *'server returned error'*) echo '원인: 대상 HTTP 오류 응답.' >&2 ;;
      *) echo '원인: 점검 명령 실패 또는 준비 대기 시간 소진. 대상 컨테이너 상태 확인 필요.' >&2 ;;
    esac
    exit 1
  fi
  echo "관측 도구의 HTTP 준비 확인 완료: ${endpoint}"
done

# 과거 재시작 이력은 허용, 이번 배포 중 늘어난 자동 재시작과 비정상 실행 상태는 실패.
# 새 Container는 비교 이력이 없으므로 자동 재시작 0회 필요.
current_states="$(container_states)"
if ! jq -e --argjson previous "${previous_states}" --argjson count "${#SERVICES[@]}" '
  length == $count and all(.[];
    . as $current |
    .State == "running" and
    .Restarts <= ([$previous[] | select(.Id == $current.Id) | .Restarts][0] // 0)
  )' <<<"${current_states}" >/dev/null; then
  echo "관측 Container 실행 상태 확인 실패. 누락·종료·재시작 여부 확인 필요." >&2
  exit 1
fi

echo "관측성 배포 완료. 실제 로그·메트릭·Trace 조회와 Telegram 수신은 별도 운영 검증 대상."
