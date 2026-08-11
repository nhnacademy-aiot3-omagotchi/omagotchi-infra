# Omagotchi Infra

학교 서버의 운영 Compose, 외부 진입점, 서비스 배포와 복구 구성입니다.

## 구성

- 외부 진입: Cloudflare Tunnel → Nginx
- 애플리케이션: Frontend, Discovery, Gateway, Identity, Learning, Rule
- 이미지 기준: GHCR commit SHA
- Runtime Secret: 저장소 밖 `secrets/prod.env`
- 배포 상태: `infra/deploy.env`
- JWT Key: Identity 전용 Private Key, 공통 Public Key

## 서버 파일

```text
~/omagotchi/
├── infra/
│   └── deploy.env
└── secrets/
    ├── prod.env
    ├── jwt-private.pem
    └── jwt-public.pem
```

- `prod.env`: DB·Redis·Broker·Token·Credential
- `deploy.env`: 서비스별 이미지 SHA·Smoke URL
- `jwt-private.pem`: Identity에만 Read-only Mount
- `jwt-public.pem`: Gateway·Identity·Learning·Rule에 Read-only Mount

## 서버 준비

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

예시 값을 실제 운영 값으로 교체한 뒤 설정을 검증합니다. 실제 Secret과 Key는 GitHub, Issue, PR, 로그에 기록하지 않습니다.

첫 배포 전 `deploy.env`의 `IDENTITY_IMAGE_TAG`와 `LEARNING_IMAGE_TAG`에 각 저장소 `main`에서 발행된 commit SHA를 입력합니다. Frontend 연동 검증 전에는 기존 `FRONTEND_IMAGE_TAG`를 유지합니다.

```bash
./scripts/compose.sh config --quiet
bash -n scripts/*.sh
```

## 배포

운영 배포 기준은 `main`입니다.

```text
feature → dev PR → dev → main PR → Build·Publish·Deploy
```

서비스 단위 배포:

```bash
./scripts/deploy-service.sh identity-service <40-character-commit-sha>
./scripts/deploy-service.sh learning-service <40-character-commit-sha>
```

Infra 전체 배포는 `main` Push의 `Deploy Infrastructure` Workflow가 담당합니다. 서비스 배포 실패 시 `deploy.env`의 직전 이미지 SHA로 자동 복구합니다.

## 확인

- 모든 컨테이너 Healthcheck 통과
- Discovery의 Identity·Learning·Gateway·Rule 등록
- Identity·Learning Flyway Migration 적용
- 외부 Rule Ping 응답
- 보호 API의 Token 없음 `401`
- 실제 JWT 정상 요청과 권한 부족 `403`
- 실행 이미지 SHA와 직전 이미지 복구 확인
