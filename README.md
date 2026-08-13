# Omagotchi Infra

Omagotchi 운영 Container·Ingress·배포 자동화 저장소.

## 담당 범위

- 외부 진입점: Cloudflare Tunnel → Nginx
- 애플리케이션 실행: Docker Compose
- 서비스 탐색: Eureka
- 이미지 저장소: GHCR
- 이미지 식별자: 40자리 Commit SHA
- 배포 자동화: GitHub Actions·Shell Script
- Container Log: `json-file`, Container별 `10MB × 3개` 순환 보관

## 운영 구성

- Frontend
- Discovery Service
- Gateway Service
- Identity Service
- Learning Service
- Rule Engine A/B
- Nginx
- Cloudflare Tunnel

운영 서비스는 `omagotchi-net` 내부 Network를 사용하며 외부 요청은 Nginx를 통해서만 수신.

## 설정 계약

### Runtime 설정

- 예시: `.env.prod.example`
- 범위: DB·Redis·Broker·Token·Credential·내부 API 공유 Secret
- 저장 원칙: Git 추적 제외, 운영 Host의 저장소 외부 보관
- Redis 저장소: Frontend Session·Learning Presence의 서로 다른 논리 DB 사용

### 배포 상태

- 예시: `deploy.env.example`
- 범위: 서비스별 이미지 SHA·Smoke Test URL
- 이미지 기준: 각 서비스 `main`에서 발행된 Commit SHA
- Secret 저장 금지

### JWT Key

- Private Key: Identity 전용 Read-only Mount
- Public Key: Gateway·Identity·Learning·Rule 공통 Read-only Mount
- 저장 원칙: Git·Issue·PR·로그 기록 금지

## 주요 파일

- `compose.yaml`: 운영 Service·Network·Healthcheck·Log Rotation
- `nginx/conf.d/default.conf`: Frontend·Gateway Route
- `scripts/compose.sh`: Runtime 설정 검증·Compose 실행 Adapter
- `scripts/deploy-infra.sh`: 전체 운영 구성 순차 배포
- `scripts/deploy-service.sh`: 단일 서비스 이미지 배포·복구
- `scripts/rule-engine.sh`: Rule A/B 상태·역할 검증
- `scripts/smoke-test.sh`: 외부 Route·인증 경계 확인
- `tests/`: Shell 배포 계약 회귀 테스트

## 로컬 검증

```bash
cp .env.prod.example /tmp/omagotchi-prod.env
cp deploy.env.example /tmp/omagotchi-deploy.env

SECRET_ENV_FILE=/tmp/omagotchi-prod.env \
DEPLOY_ENV_FILE=/tmp/omagotchi-deploy.env \
  ./scripts/compose.sh config --quiet

bash -n scripts/*.sh tests/*.sh
shellcheck scripts/*.sh tests/*.sh
```

- 실제 운영 Secret 사용 금지
- 예시 값의 Compose 해석·Shell 문법 검증만 수행

## 배포 원칙

- 기준 흐름: `feature → dev PR → dev → main PR`
- 서비스 `main`: 이미지 Build·Publish
- Infra `main`: 구성 검증·승인된 운영 배포
- 자동 배포 조건: 저장소 변수 `DEPLOY_ENABLED=true`
- 초기 운영 검증: `DEPLOY_ENABLED=false` 상태의 수동 실행
- Discovery 변경: Eureka Client보다 먼저 배포
- Rule A/B 변경: 두 Instance 동시 재생성 금지
- 완료 판단: CI 성공과 실제 운영 Health·Route 검증의 분리

## 운영 안전 기준

- 필수 설정 누락 시 실행 중단
- Runtime 설정과 배포 상태의 파일 분리
- Rule 내부 API의 Gateway 미라우팅
- JWT Private Key의 Identity 전용 사용
- Container Host Port의 최소 노출
- Healthcheck 통과 전 배포 완료 처리 금지
- 실패 시 직전 이미지 SHA 기반 복구
- Secret·Token·Password의 출력 금지

## 운영 절차

- [운영 Runbook](docs/operations.md)
