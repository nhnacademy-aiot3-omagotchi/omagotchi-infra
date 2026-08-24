# 운영 Runbook

Infra 운영 담당자를 위한 Host 준비·배포·검증 절차.

## 적용 범위

- 최초 운영 Host 준비
- Runtime 설정·JWT Key 배치
- Rule 제외 초기 배포
- 전체 Infra 배포
- 배포 후 확인·복구

## Host 파일 계약

배포 Script 기준 상대 경로:

```text
<runtime-root>/
├── infra/
│   └── deploy.env
└── secrets/
    ├── prod.env
    ├── jwt-private.pem
    └── jwt-public.pem
```

- `<runtime-root>`: 운영 담당자가 선택한 배치 경로
- `prod.env`: Runtime 설정·Secret
- `deploy.env`: 이미지 SHA·Smoke Test URL
- `jwt-private.pem`: Identity 전용
- `jwt-public.pem`: JWT 검증 서비스 공통
- 실제 Host 절대 경로·계정명: 문서화 제외

## 최초 파일 준비

Infra 저장소에서 실행:

```bash
mkdir -p ../secrets
cp .env.prod.example ../secrets/prod.env
cp deploy.env.example deploy.env

openssl genpkey \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:2048 \
  -out ../secrets/jwt-private.pem

openssl pkey \
  -in ../secrets/jwt-private.pem \
  -pubout \
  -out ../secrets/jwt-public.pem

chmod 700 ../secrets
chmod 600 ../secrets/prod.env ../secrets/jwt-private.pem
chmod 644 ../secrets/jwt-public.pem
```

### Runtime 설정

- `prod.env`: 예시 값을 실제 운영 값으로 교체
- DB·Redis·RabbitMQ·InfluxDB: 운영 Network 기준 주소 사용
- Redis 논리 DB: Frontend `340`, Learning `341`
- `INTERNAL_SHARED_SECRET`: Rule Engine A/B 동일 난수
- `RULE_LEARNING_USERNAME`·`RULE_LEARNING_PASSWORD`: Learning과 Rule Engine A/B에 동일한 관계 전용 Credential 주입
- `deploy.env`: 발행 완료된 서비스별 `main` Commit SHA 입력
- Secret·Key 기록 금지: GitHub, Issue, PR, 메신저, 로그

## 배포 전 검증

```bash
./scripts/compose.sh config --quiet
bash -n scripts/*.sh tests/*.sh
shellcheck scripts/*.sh tests/*.sh
```

- Git 상태: `main`, 추적 파일 변경 없음
- Image SHA: GHCR 발행 확인
- Runtime 설정: 필수 항목·파일 권한 확인
- 외부 자원: 운영 Host 기준 Network 연결 확인
- 자동 배포: 최초 검증 완료 전 `DEPLOY_ENABLED=false`

## Rule 제외 초기 배포

Rule hot-standby 준비 전 나머지 운영 경로 확인을 위한 임시 절차.

```bash
./scripts/deploy-infra.sh \
  --skip-rule \
  "$PWD" \
  <40-character-infra-commit-sha>
```

- 기동 대상: Discovery, Frontend, Gateway, Identity, Learning, Nginx, Cloudflare
- 제외 대상: Rule Engine A/B·Rule Ping
- 기존 Rule Container: 제거·재생성 없음
- Rule 전용 대체값: Compose 해석 전용, Container 주입 금지
- 예상 상태: Rule 공개 API의 일시적 `503`
- 완료 기준: `인프라 부분 배포 완료` 출력·대상 서비스 Health 통과
- 폐기 시점: Rule A/B 운영 준비 완료 후 전체 배포 전환

## 전체 Infra 배포

```bash
./scripts/deploy-infra.sh \
  "$PWD" \
  <40-character-infra-commit-sha>
```

- 선행 조건: 전체 서비스 이미지 발행·Runtime 설정 완료
- 배포 순서: Discovery → Eureka Client → Rule Engine A/B → Ingress
- Rule 초기화: 물리 Instance별 순차 기동·역할 안정화
- Rule 후속 배포: 현재 STANDBY부터 순차 교체
- Rule 완료 조건: 두 Engine 등록·연속 3회 exactly-one-ACTIVE
- 자동 배포 전환: 최초 수동 배포·복구 검증 이후 별도 결정

## 운영 확인

- 모든 대상 Container Healthcheck 통과
- Container Log Rotation 적용
- Frontend의 Eureka Registry 조회 정상
- Discovery의 Gateway·Identity·Learning 등록
- Rule 포함 배포 시 `engine-a`·`engine-b` 등록
- Rule 포함 배포 시 정확히 하나의 `ACTIVE`·하나의 `STANDBY`
- Identity·Learning Flyway Migration 성공
- 공개 화면·보호 API 정상 응답
- Token 미제공 `401`, 권한 부족 `403`
- Gateway의 `/api/v1/internal/**` 미라우팅
- 실행 이미지 SHA와 `deploy.env` 일치

## 실패 대응

- 배포 완료 메시지 이전 실패: 부분 적용 가능성 확인
- Container 상태: `./scripts/ps.sh`
- Service 로그: `./scripts/logs.sh <service>`
- 단일 서비스 복구: `deploy.env`의 직전 SHA로 `deploy-service.sh` 실행
- Rule 복구: Script의 역순 복구 결과·A/B 역할 재확인
- 기존 `omagotchi-net` 소유 Label 경고: 실행 중 Network 제거 금지, 전체 중단이 가능한 정비 시간에 Compose Network 재생성
- 자동 재시도 금지: 원인·현재 실행 SHA·Eureka 등록 상태 확인 후 재실행
