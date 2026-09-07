#!/usr/bin/env bash
set +x
set -euo pipefail

# 전체 Infra 배포의 관측성 단계. Revision 확인·배포 Lock은 deploy-infra.sh의 책임.
# 초기화·Volume 삭제·업무 Container 변경 없이 기존 관측 저장소 재사용.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICES=(filebeat elastalert prometheus grafana otel-collector tempo)

compose() {
  "${SCRIPT_DIR}/observability-compose.sh" \
    --profile alerts --profile metrics --profile tracing "$@" </dev/null
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
if ! compose run --rm -T --no-deps elastalert check; then
  echo "관측 저장소 준비 실패. 기존 자원·부분 생성 여부 확인 필요. 자동 초기화 없음." >&2
  exit 1
fi
if ! compose run --rm -T --no-deps filebeat \
  filebeat test output --strict.perms=false -e -E logging.level=error \
  -E output.elasticsearch.timeout=5s >/dev/null 2>&1; then
  echo "Filebeat의 Elasticsearch 연결 확인 실패. 기존 수집기 유지." >&2
  exit 1
fi

# Bind Mount 내용 변경은 Compose의 재생성 판단에 포함되지 않으므로 명시적 재생성.
# 별도 관측 프로젝트의 여섯 Runtime만 대상, setup Profile·Volume 삭제 제외.
compose up -d --no-deps --force-recreate --wait --wait-timeout 180 "${SERVICES[@]}"

# Running 상태와 HTTP 준비 상태의 구분. 기존 Prometheus 이미지의 wget 재사용.
# Collector·Tempo 확인을 위한 Host Port·진단 Container 추가 없음.
deadline=$((SECONDS + 180))
for endpoint in \
  http://127.0.0.1:9090/-/ready \
  http://grafana:3000/api/health \
  http://otel-collector:13133/ \
  http://tempo:3200/ready; do
  ready=false
  while ((SECONDS < deadline)); do
    if compose exec -T --interactive=false prometheus \
      wget -q -T 5 -O /dev/null "${endpoint}" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 2
  done
  if [[ "${ready}" != true ]]; then
    echo "관측 도구의 HTTP 준비 확인 실패: ${endpoint}" >&2
    exit 1
  fi
done

# 재시작 Loop의 잠깐 Running인 순간을 성공으로 처리하지 않는 경계.
# 이번 배포에서 모두 재생성했으므로 자동 재시작 횟수는 0이어야 함.
container_ids=()
while IFS= read -r container_id; do
  [[ -z "${container_id}" ]] || container_ids+=("${container_id}")
done < <(compose ps --all --quiet "${SERVICES[@]}")
if ((${#container_ids[@]} != ${#SERVICES[@]})) || \
  ! docker inspect --format '{"State":"{{.State.Status}}","Restarts":{{.RestartCount}}}' "${container_ids[@]}" \
    | jq -se 'length == 6 and all(.State == "running" and .Restarts == 0)' >/dev/null; then
  echo "관측 Container 실행 상태 확인 실패. 누락·종료·재시작 여부 확인 필요." >&2
  exit 1
fi

echo "관측성 배포 완료. 실제 로그·메트릭·Trace 조회와 Telegram 수신은 별도 운영 검증 대상."
