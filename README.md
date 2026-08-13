# Omagotchi Infra

학교 서버 운영 인프라 구성.

## 역할

- 외부 진입점: Cloudflare Tunnel → Nginx
- 애플리케이션: Frontend, Discovery, Gateway, Identity, Learning, Rule Engine A/B
- 이미지 저장소: GHCR
- 이미지 식별자: 40자리 Commit SHA
- 운영 구성: Docker Compose
- Container Log: `json-file`, Container별 `10MB × 3개` 순환 보관
- Runtime Secret: 저장소 외부 `secrets/prod.env`
- 배포 상태: `infra/deploy.env`
- JWT Private Key: Identity 전용
- JWT Public Key: Gateway·Identity·Learning·Rule 공통

## 파일 배치

```text
~/omagotchi/
├── infra/
│   └── deploy.env
└── secrets/
    ├── prod.env
    ├── jwt-private.pem
    └── jwt-public.pem
```

- `prod.env`: DB·Redis·Broker·Token·Credential·내부 API 공유 Secret
- `deploy.env`: 서비스별 이미지 SHA·Smoke Test URL
- `jwt-private.pem`: Identity 전용 Read-only Mount
- `jwt-public.pem`: Gateway·Identity·Learning·Rule 공통 Read-only Mount

## 최초 준비

### 파일 생성

```bash
mkdir -p ../secrets
cp .env.prod.example ../secrets/prod.env
cp deploy.env.example deploy.env

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out ../secrets/jwt-private.pem
openssl pkey -in ../secrets/jwt-private.pem -pubout \
  -out ../secrets/jwt-public.pem

chmod 700 ../secrets
chmod 600 ../secrets/prod.env ../secrets/jwt-private.pem
chmod 644 ../secrets/jwt-public.pem
```

### 운영 값 설정

- `prod.env`: 예시 값을 실제 운영 값으로 교체
- `IDENTITY_IMAGE_TAG`: Identity `main`에서 발행된 Commit SHA
- `LEARNING_IMAGE_TAG`: Learning `main`에서 발행된 Commit SHA
- `FRONTEND_IMAGE_TAG`: Frontend 연동 검증 전까지 기존 값 유지
- `INTERNAL_SHARED_SECRET`: 충분히 긴 임의 값, Rule Engine A/B 공통 사용
- Secret·Key 기록 금지: GitHub, Issue, PR, 로그

### 설정 검증

```bash
./scripts/compose.sh config --quiet
bash -n scripts/*.sh
```

## 배포 기준

- 기준 브랜치: `main`
- Identity·Learning `main` Push: 이미지 Build·Publish
- Infra `main` Push: Compose·Shell 검증
- 자동 운영 배포 조건: Infra 저장소 변수 `DEPLOY_ENABLED=true`
- 현재 자동 배포 상태: `DEPLOY_ENABLED=false`
- 현재 배포 방식: 초기 운영 검증을 위한 서비스별 수동 배포
- Discovery 변경 배포: 다른 Eureka Client보다 먼저 실행
- Rule 배포: 현재 STANDBY 물리 인스턴스부터 순차 교체

```text
feature → dev PR → dev → main PR → Build·Publish
```

## 초기 운영 배포

- 전체 배포 선행 조건: Identity·Learning·Rule 이미지 발행
- 실행 위치: 학교 서버의 Infra 저장소
- `deploy.env`: 새 Discovery·Rule 이미지 SHA 설정
- `prod.env`: `INTERNAL_SHARED_SECRET` 설정
- 실행 방식: Infra 배포 스크립트

```bash
./scripts/deploy-infra.sh <40-character-infra-commit-sha>
```

- 초기 순서: Discovery 갱신 → 기존 Client 재등록 → Engine A → Engine B
- 기존 단일 Rule 컨테이너: A/B 기동 전 제거
- 후속 개별 서비스 배포: `deploy-service.sh`
- Rule 논리 대상: `rule-service`
- Rule 실제 대상: `rule-engine-a`, `rule-engine-b`
- Rule 후속 배포: 현재 역할 안정화 → STANDBY 물리 인스턴스 교체 → 역할 재검증 → 반대편 물리 인스턴스 교체
- Rule 후속 배포 실패: 마지막 교체 대상부터 `deploy.env`의 직전 이미지 SHA로 역순 복구
- Rule 개별 배포 선행 조건: 두 인스턴스 등록·역할 안정화
- Infra 전체 배포의 단일 인스턴스 상태: 누락 인스턴스 복구 → 역할 안정화 → 기존 인스턴스 교체
- Rule 배포 완료 조건: 두 엔진 Eureka 등록·연속 3회 exactly-one-ACTIVE
- 초기 검증 완료: `DEPLOY_ENABLED=true` 전환 검토
- 전환 이후: Infra `main` Push의 `Deploy Infrastructure` Workflow 실행

### Rule 제외 최초 수동 배포

- 목적: Rule hot-standby 완료 전 운영 네트워크·인증·Learning 연동 확인
- 적용 대상: Discovery, Frontend, Gateway, Identity, Learning, Nginx, Cloudflare
- 제외 대상: Rule Engine A/B 기동·역할 확인·Rule Ping
- 유지 검증: 공개 화면, Health, 인증 경계, Rule 내부 API 미노출
- 기존 Rule Container: 제거·재생성 없음
- 자동 배포: 미사용, `DEPLOY_ENABLED=false` 유지

```bash
./scripts/deploy-infra.sh --skip-rule <40-character-infra-commit-sha>
```

- 예상 상태: Rule 공개 API의 일시적 `503`
- 완료 기준: 출력의 `인프라 부분 배포 완료` 확인
- Rule 준비 이후: `--skip-rule` 없는 전체 배포 수행

## Rule Engine A/B

- 공통 애플리케이션명: `rule-service`
- 공통 이미지: `RULE_IMAGE_TAG`
- 공통 내부 인증: `INTERNAL_SHARED_SECRET`
- Engine A: `engine-a`, Priority `1`, MQTT Client `rule-engine-a`
- Engine B: `engine-b`, Priority `2`, MQTT Client `rule-engine-b`
- 외부 Host Port: 미노출
- Gateway 대상: `lb://rule-service`
- 내부 API: `/api/v1/internal/**`, Gateway 미라우팅
- Discovery Cache: Read-only 응답 캐시 비활성화
- 잔여 지연: Eureka Client Registry Fetch 주기
- 보장 범위: 초기 Registry 가시성 개선, 강한 분산 Lock·Fencing 미제공

## 운영 확인

- 모든 컨테이너 Healthcheck 통과
- 모든 컨테이너 Log Rotation 적용
- Discovery의 Frontend·Identity·Learning·Gateway 등록
- Discovery의 `engine-a`·`engine-b` 등록
- Rule 역할: 정확히 하나의 `ACTIVE`, 하나의 `STANDBY`
- Rule 내부 폴링: `403` 미발생
- MQTT 구독: `ACTIVE` 전용
- 장애 전환: `ACTIVE` 종료 후 `STANDBY` 승격
- 재기동: exactly-one-ACTIVE 복구
- Identity·Learning Flyway Migration 적용
- 외부 Rule Ping 응답
- Gateway의 `/api/v1/internal/**` 미라우팅
- 보호 API의 Token 미제공 응답 `401`
- 정상 JWT 요청 성공
- 권한 부족 응답 `403`
- 실행 이미지 SHA 확인
- 직전 이미지 복구 확인
