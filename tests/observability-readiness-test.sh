#!/usr/bin/env bash
set -euo pipefail

# 운영 Compose의 네 관측 도구로 HTTP 준비 점검. 외부 통신은 차단하고
# 테스트 전용 프로젝트·볼륨·가짜 인증값만 사용, 학교 ES·Telegram 접속 없음.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
TEST_PROJECT="omagotchi-readiness-test-$$"

compose() {
  docker compose --project-name "${TEST_PROJECT}" --file "${TEST_TMP_DIR}/compose.json" "$@" </dev/null
}
cleanup() {
  compose down --volumes --timeout 5 >/dev/null 2>&1 || true
  rm -rf -- "${TEST_TMP_DIR}"
}
trap cleanup EXIT

# 학교 서버에서 nslookup은 성공하고 wget은 실패했던 resolver 설정.
cat >"${TEST_TMP_DIR}/resolv.conf" <<'EOF'
nameserver 127.0.0.11
search .
options edns0 trust-ad ndots:0
EOF
chmod 755 "${TEST_TMP_DIR}"
chmod 644 "${TEST_TMP_DIR}/resolv.conf"

docker compose --env-file "${INFRA_DIR}/.env.prod.example" \
  --env-file "${INFRA_DIR}/deploy.env.example" --file "${INFRA_DIR}/compose.yaml" \
  config --format json >"${TEST_TMP_DIR}/app-compose.json"

docker compose --env-file "${INFRA_DIR}/.env.prod.example" \
  --file "${INFRA_DIR}/observability/compose.yaml" --profile metrics --profile tracing config --format json \
  | jq --arg resolver "${TEST_TMP_DIR}/resolv.conf" --slurpfile app "${TEST_TMP_DIR}/app-compose.json" '
    if .networks["grafana-ingress"].name != $app[0].networks["grafana-ingress"].name
    then error("업무·관측 Compose의 Grafana 연결 Network 불일치") else . end
    | . as $observability
    |
    {services: {grafana: .services.grafana, prometheus: .services.prometheus,
                "otel-collector": .services["otel-collector"], tempo: .services.tempo},
     networks: {default: {internal: true}, "grafana-ingress": {internal: true}},
     volumes: {"grafana-data": {}, "prometheus-data": {}, "tempo-data": {}}}
    | .services[].networks |= del(.app)
    | .services[].restart = "no"
    | del(.services[].profiles, .services.grafana.ports)
    | .services.grafana.environment.GF_SECURITY_ADMIN_PASSWORD = "fixture-password"
    | .services.grafana.environment.OPS_TELEGRAM_BOT_TOKEN = "fixture-token"
    | .services.grafana.environment.OPS_TELEGRAM_CHAT_ID = "-100123"
    | .services.prometheus.volumes += [{type: "bind", source: $resolver,
        target: "/etc/resolv.conf", read_only: true}]
    | .services["ingress-probe"] = {
        image: $observability.services.prometheus.image,
        entrypoint: ["/bin/sh", "-c", "sleep 3600"],
        networks: ($app[0].services.cloudflared.networks | del(.["omagotchi-net"]))
      }
  ' >"${TEST_TMP_DIR}/compose.json"

compose up -d --wait --wait-timeout 90 >"${TEST_TMP_DIR}/startup.log" 2>&1 || {
  cat "${TEST_TMP_DIR}/startup.log"
  exit 1
}

deadline=$((SECONDS + 180))
for endpoint in \
  http://127.0.0.1:9090/-/ready \
  http://grafana.:3000/api/health \
  http://otel-collector.:13133/ \
  http://tempo.:3200/ready; do
  until compose exec -T --interactive=false prometheus \
    wget -q -T 5 -O /dev/null "${endpoint}" \
    >"${TEST_TMP_DIR}/health.log" 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "HTTP 준비 확인 실패: ${endpoint}" >&2
      cat "${TEST_TMP_DIR}/health.log"
      compose logs --tail=30 --no-color
      exit 1
    fi
    sleep 2
  done
done
compose exec -T --interactive=false prometheus \
  wget -q -T 5 -O - http://grafana.:3000/api/health \
  | jq -e '.database == "ok"' >/dev/null

echo 'Prometheus·Grafana·Collector·Tempo의 search . 환경 HTTP 준비 응답 검증 통과.'

# 실제 Tunnel 대신 기존 이미지의 HTTP 도구 사용. 새 인입 Network의 연결·인증 경계 점검.
compose exec -T --interactive=false ingress-probe wget -q -T 5 -O - http://grafana:3000/login \
  >"${TEST_TMP_DIR}/login.html"
grep -Fq 'https://grafana.omagotchi.site/' "${TEST_TMP_DIR}/login.html"

if compose exec -T --interactive=false ingress-probe wget -S -T 5 -O /dev/null \
  http://grafana:3000/api/user >"${TEST_TMP_DIR}/anonymous.log" 2>&1; then
  echo '인증 없는 Grafana 사용자 정보 접근 허용' >&2
  exit 1
fi
grep -q 'HTTP/1.1 401' "${TEST_TMP_DIR}/anonymous.log"

compose exec -T --interactive=false ingress-probe wget -S -T 5 -O /dev/null \
  --header 'Content-Type: application/json' \
  --header 'Host: grafana.omagotchi.site' --header 'X-Forwarded-Proto: https' \
  --header 'Origin: https://grafana.omagotchi.site' \
  --post-data '{"user":"omagotchi-admin","password":"fixture-password"}' \
  http://grafana:3000/login >"${TEST_TMP_DIR}/login.log" 2>&1
grep -Eq 'Set-Cookie: grafana_session=.*; Secure;' "${TEST_TMP_DIR}/login.log"

# 전용 인입 Network에 저장소·수집기를 추가하지 않았는지 확인. 기존 앱 Network는 별도.
for endpoint in http://prometheus:9090/-/ready http://tempo:3200/ready http://otel-collector:13133/; do
  if compose exec -T --interactive=false ingress-probe wget -q -T 2 -O /dev/null "${endpoint}" \
    >"${TEST_TMP_DIR}/isolation.log" 2>&1; then
    echo "Grafana 인입 Network의 관측 도구 직접 접근 허용: ${endpoint}" >&2
    exit 1
  fi
done
echo 'Grafana 인입 연결·로그인·Secure Cookie·전용 Network 분리 검증 통과.'
