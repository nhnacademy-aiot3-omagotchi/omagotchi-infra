# 운영 Runbook

Infra 운영 담당자를 위한 Host 준비·배포·검증 절차.

## 적용 범위

- 최초 운영 Host 준비
- Runtime 설정·JWT Key 배치
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
    ├── prod.env.previous
    ├── jwt-private.pem
    └── jwt-public.pem
```

- `<runtime-root>`: 운영 담당자가 선택한 배치 경로
- `prod.env`: Runtime 설정·Secret
- `prod.env.previous`: 마지막 Runtime 설정 동기화 직전 복구본, 최초 준비 시 미생성
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
- Redis 논리 DB: Frontend `340`, Learning `341`, Identity Email Verification `342`
- `INTERNAL_SHARED_SECRET`: Rule Engine A/B 동일 난수
- `RULE_LEARNING_USERNAME`·`RULE_LEARNING_PASSWORD`: Learning과 Rule Engine A/B에 동일한 관계 전용 Credential 주입
- `deploy.env`: 발행 완료된 서비스별 `main` Commit SHA 입력
- `prod.env`의 GitHub 저장: `production` Environment의 `PROD_ENV` Secret 한 개만 허용
- Secret·Key 기록 금지: Git 추적 파일, Issue, PR, 메신저, 로그

## Runtime 설정 동기화

- 등록 단위: GitHub `production` Environment의 `PROD_ENV` Secret 한 개
- 등록 내용: `prod.env` 전체 내용
- 분리 정책: 키별 GitHub Secret 분리 미사용
- 제외 대상: JWT Key·`deploy.env`
- Workflow 표시 조건: 기본 브랜치 반영
- 실행 Reference: `main`

### 설정 변경 절차

- 후보 검증: 전체 `prod.env`의 필수값·중복 Key 확인
- Secret 교체: GitHub `production` Environment의 `PROD_ENV` 전체 교체
- 동기화 실행: Infra `main`의 `Sync Runtime Configuration` Workflow 수동 실행
- 결과 확인: Workflow 성공·서버 `prod.env` 권한 `600` 확인
- 설정 적용: 영향 서비스만 별도 배포

### 동기화 처리 순서

- 후보 전송: Runner 임시 파일 생성·서버 `.incoming-prod.env.*` 전송
- 배타 실행: 서비스·Infra 배포와 동일한 공용 Lock을 최대 600초 대기
- Source 동기화: 서버 Infra 저장소를 Workflow의 `main` Revision으로 Fast-forward
- 설정 검증: 현재 `deploy.env`·후보 `prod.env`의 Compose 설정 검증
- 직전본 보존: 기존 `prod.env`를 `prod.env.previous`로 백업
- 설정 확정: 후보 파일의 `prod.env` 원자적 교체·권한 `600` 적용

### 안전 경계

- 실행 제외: Container 재시작·재생성 및 `deploy.env` 변경
- Kill Switch 분리: 전체 Infra 배포 전용 `DEPLOY_ENABLED` 미사용
- 검증 실패: 기존 `prod.env`·실행 중인 Container 상태 유지
- Source 선반영: Infra Fast-forward 이후 설정 검증 실패 가능, 실행 중인 Compose 구성 자동 적용 없음
- 복구본 유지: 서버의 검증 성공본·직전 복구본 유지
- Secret 보호: 후보·Runner 임시 파일 및 Secret 내용의 Log 출력 금지

## 배포 전 검증

```bash
./scripts/compose.sh config --quiet
bash -n scripts/*.sh tests/*.sh
shellcheck scripts/*.sh tests/*.sh
```

- Git 상태: `main`, 추적 파일 변경 없음
- Image SHA: GHCR 발행 확인
- Runtime 설정: 필수 항목·파일 권한 확인
- Runtime 설정 변경: `Sync Runtime Configuration` 성공 후 서비스별 적용 시점 결정
- 외부 자원: 운영 Host 기준 Network 연결 확인
- Infra `main` Push: 구성 검증만 수행하며 전체 배포는 실행하지 않음
- 전체 배포: `main` 대상 `workflow_dispatch` 실행 전 `DEPLOY_ENABLED=true`로 일시 활성화
- 배포 종료 후: `DEPLOY_ENABLED=false` 복원

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
- 배포 실행: `main` 대상 `workflow_dispatch`와 `DEPLOY_ENABLED=true`를 모두 요구
- 동시 실행: 기존 서비스·Infra 배포가 있으면 공용 Lock을 최대 600초 대기
- 잠금 시간 초과: 실행 중인 배포를 중단하지 않고 새 배포만 실패

## 운영 확인

- 모든 대상 Container Healthcheck 통과
- Container Log Rotation 적용
- Frontend의 Eureka Registry 조회 정상
- Discovery의 Gateway·Identity·Learning 등록
- Rule `engine-a`·`engine-b` 등록
- Rule 역할: `ACTIVE` 1개·`STANDBY` 1개
- Identity·Learning Flyway Migration 성공
- 공개 화면·보호 API 정상 응답
- Token 미제공 `401`, 권한 부족 `403`
- Gateway의 `/api/v1/internal/**` 미라우팅
- 실행 이미지 SHA와 `deploy.env` 일치

## 실패 대응

- 배포 완료 메시지 이전 실패: 부분 적용 가능성 확인
- Container 상태: `./scripts/compose.sh ps`
- Service 로그: `./scripts/compose.sh logs -f <service>`
- 단일 서비스 복구: `deploy.env`의 직전 SHA로 `deploy-service.sh` 실행
- Rule 복구: Script의 역순 복구 결과·A/B 역할 재확인
- 기존 `omagotchi-net` 소유 Label 경고: 실행 중 Network 제거 금지, 전체 중단이 가능한 정비 시간에 Compose Network 재생성
- Runtime 설정 동기화 실패: 기존 `prod.env` 유지 여부·후보 검증 오류·Infra Git 상태·공용 Lock 확인
- Runtime 설정 복구: `prod.env.previous`를 후보로 별도 검증한 뒤 `prod.env` 복원, 영향 서비스만 재배포
- 자동 재시도 금지: 원인·현재 실행 SHA·Eureka 등록 상태 확인 후 재실행
