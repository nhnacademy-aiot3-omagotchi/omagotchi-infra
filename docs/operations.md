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
- Infra 변경 동반: Infra `main` 반영 시 자동 배포가 Runtime 설정 동기화 후 전체 배포 수행
- 설정만 변경: Infra `main`의 `Sync Runtime Configuration` Workflow 수동 실행
- 결과 확인: Workflow 성공·서버 `prod.env` 권한 `600` 확인
- 수동 동기화 적용: 영향 서비스만 별도 배포

### 동기화 처리 순서

- 후보 전송: Runner 임시 파일 생성·서버 `.incoming-prod.env.*` 전송
- 배타 실행: 서비스·Infra 배포와 동일한 공용 Lock을 최대 600초 대기
- Source 동기화: 서버 Infra 저장소를 Workflow의 `main` Revision으로 Fast-forward
  - Git 파일 갱신에만 `umask 022` 적용, 후보·복구본 생성에는 `umask 077` 유지
- 설정 검증: 현재 `deploy.env`·후보 `prod.env`의 Compose 설정 검증
- 변경 없음: 현재 `prod.env`와 동일하면 기존 복구본을 유지하고 교체 생략
- 직전본 보존: 기존 `prod.env`를 `prod.env.previous`로 백업
- 설정 확정: 후보 파일의 `prod.env` 원자적 교체·권한 `600` 적용

### 수동 동기화 안전 경계

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
- Infra `main` Push: 구성 검증·Runtime 설정 동기화 성공 후 전체 배포 실행
- Kill Switch: 저장소 변수 `DEPLOY_ENABLED=true`일 때만 자동·수동 전체 배포 실행
- 활성화 시점: Infra main 반영 전에 `DEPLOY_ENABLED=true` 확인, 뒤늦게 바꾼 경우 수동 재실행 필요
- 배포 중단: 운영 장애나 정비 시 `DEPLOY_ENABLED=false`로 전환

## 전체 Infra 배포

```bash
./scripts/deploy-infra.sh \
  "$PWD" \
  <40-character-infra-commit-sha>
```

- 선행 조건: 전체 서비스 이미지 발행·Runtime 설정·중앙 로그 저장소 준비 완료
- 알림 상태 저장소: 전체 부재 시 동일 배포 Lock 안에서 최초 생성, 준비된 경우 재사용
- 배포 순서: Discovery → Eureka Client → Rule Engine A/B → Ingress·Smoke Test → 관측성
- Container 명령: `exec -T --interactive=false`, SSH로 전달한 배포 Script의 표준 입력과 분리
  - `-T`만 사용하면 TTY만 해제, 남은 배포 Script를 소비한 뒤 성공 종료하는 현상 가능
- 공개 관측 파일: Container 시작 전 Bind Mount 읽기·탐색 권한 복구, Secret 권한 변경 없음
- Rule 초기화: 물리 Instance별 순차 기동·역할 안정화
- Rule 후속 배포: 현재 STANDBY부터 순차 교체
- Rule 완료 조건: 두 Engine 등록·연속 3회 exactly-one-ACTIVE
- 자동 배포: `main` Push와 `DEPLOY_ENABLED=true`를 모두 요구
- 수동 재실행: `main` 대상 `workflow_dispatch`와 `DEPLOY_ENABLED=true`를 모두 요구
- Runtime 설정: 자동·수동 전체 배포 모두 GitHub `PROD_ENV` 동기화 성공을 선행 조건으로 사용
- Trigger 제외: Test와 PR 검증 Workflow만 변경된 main 반영은 전체 배포를 실행하지 않음
- Workflow 직렬화: 연속 main 반영은 Infra 자동 배포 Workflow 단위로 직렬화
- 동시 실행: 기존 서비스·Infra 배포가 있으면 공용 Lock을 최대 600초 대기
- 잠금 시간 초과: 실행 중인 배포를 중단하지 않고 새 배포만 실패

### 관측성 자동배포

- 대상: Filebeat·ElastAlert2·Prometheus·Grafana·Collector·Tempo
- 실행 위치: `deploy-infra.sh`의 마지막 단계, 같은 배포 Lock·Revision 사용
  - 업무 서비스와 다른 Compose 프로젝트 유지, `observability/**` 변경도 배포 Trigger에 포함
  - 개별 서비스 배포와 `Sync Runtime Configuration`만 실행한 경우에는 관측 도구 변경 없음
- 준비 확인: 필수 Secret·Image 다운로드·로그 Data Stream·알림 상태 자동 준비·Filebeat 연결
  - `elastalert prepare`: 다섯 쓰기 Alias가 준비됐으면 재사용, 모든 관련 자원이 없으면 최초 생성
  - 일부 Index·Alias·Template·ILM 존재 또는 조회 실패 시 생성·덮어쓰기 없이 중단
  - 중앙 로그 저장소 최초 준비는 [중앙 로그·오류 알림](../observability/README.md)의 기존 절차 사용
  - 준비 실패 시 실행 중인 관측 도구 유지, 생성 도중 실패한 경우 부분 상태의 수동 확인 필요
- 반영 방식: `observability-compose.sh`를 통한 변경 대상만 재생성, 기존 Named Volume 유지
  - 도구별 공개 설정 파일의 내용·경로 해시를 `site.omagotchi.config-revision` Label에 반영
  - Image·환경변수·Compose 설정·위 Label 변경은 일반 `up`에서 판단, 변경 없는 컨테이너 유지
  - Secret·저장 데이터는 해시 대상에서 제외, Secret 교체는 해당 환경변수 변경으로 반영
  - 첫 적용 시 Label이 없는 기존 도구의 한 차례 재생성, 별도 배포 이력 파일·운영 환경변수 등록 불필요
  - 직접 `docker compose` 실행 시 설정 파일의 내용 변경 감지 제외, 운영 진입점은 Adapter로 통일
  - 변경된 도구의 재생성 중 짧은 수집 공백 가능, Trace·알림의 무손실 보장 아님
- 완료 조건: 네 도구의 HTTP 준비 응답과 여섯 Runtime Container의 실행 상태
  - 점검 시작·완료 Endpoint 출력, DNS·연결·HTTP 오류의 구분
  - Prometheus의 wget에서 `grafana.`·`otel-collector.`·`tempo.` 사용
    - 서버 resolver의 `search .` 환경에서 짧은 이름 조회가 실패하는 상황 방지
  - 새 Container의 자동 재시작 0회, 유지한 Container는 배포 전보다 자동 재시작 횟수가 늘지 않는 상태
  - 과거 재시작 이력만으로 실패 처리하지 않는 기준, 이번 배포 중 재시작 증가·비정상 상태는 실패
  - 전체 서비스 Scrape·Trace 저장·Telegram 수신은 별도 운영 검증
- 실패 처리: Actions 실패, 이미 배포된 업무 서비스의 자동 Rollback 없음
  - 관측성 로그·저장소 준비 상태 확인 후 `main`의 `Deploy Infrastructure` 재실행
  - 배포 재실행 시 업무 서비스 단계도 포함, 관측성 보조 Script의 단독 실행은 공용 Lock 미적용
  - 복구를 위한 `down --volumes`·초기화 무조건 재실행 금지

- 근거: [Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)
  - 서비스 설정·Image 변경 시 재생성, 연결된 Volume 유지
  - 공개 설정의 내용 해시 Label은 Bind Mount 파일 변경을 Compose 설정 변경으로 전달하기 위한 팀 구현

## 이전 서비스 이미지 정리

- 실행 시점: 개별 서비스의 새 SHA 배포 성공 후, 같은 배포 Lock 안에서 실행
  - Healthcheck·외부 Smoke Test 통과와 `deploy.env` 갱신 이후
  - Rule은 A/B 순차 교체·역할 확인까지 성공한 뒤 한 번 실행
- 정리 대상: 방금 배포한 서비스의 팀 GHCR 저장소와 일치하는 로컬 40자리 SHA 태그
  - 예시: Frontend 배포 시 `ghcr.io/nhnacademy-aiot3-omagotchi/omagotchi-frontend`만 대상
  - 현재 성공 이미지·직전 성공 이미지 보존, 같은 이미지의 다른 태그도 보존
  - 실행 중이거나 중지된 Container의 참조 이미지 보존, 다른 팀 Container도 포함
- 제외 대상: 다른 서비스·다른 팀 이미지, `main`·수동 태그, 태그 없는 이미지, 관측 도구 이미지
  - Volume·로그·Build Cache·GHCR 원격 이미지의 삭제 없음
  - 전체 `prune`·강제 삭제 미사용, 공통 이미지 Layer의 실제 회수량 차이 가능
- 정리 생략: 배포 실패·같은 SHA 재배포·전체 Infra 배포
  - 같은 SHA 재배포에서는 직전의 다른 성공 SHA 확인이 어려우므로 기존 이미지 유지
  - 누적 이미지도 각 서비스의 다음 새 SHA 배포 성공 시 같은 기준으로 정리
  - 별도 이력 파일·일괄 수동 정리 불필요, 새 배포가 없는 서비스의 기존 이미지 유지
- 실패 처리: 이미지·Container 조회 실패 시 정리 중단, 삭제 실패 시 남은 정리 중단
  - 성공한 배포 상태 유지, 자동 Rollback 없음
  - 다음 새 SHA 배포 시 재시도, 반복 경고 시 Docker 상태·이미지 존재 여부 확인
- 확인 위치: 서비스 배포 Actions의 `이전 서비스 이미지 정리`·`경고: 이전 이미지 정리 실패` 출력
  - 정리 후 서버의 `docker system df`로 사용량 확인 가능
  - 필요 시 남아 있는 GHCR SHA 태그의 재다운로드 가능, 원격 태그 보존 기간은 별도
- 근거: [로컬 이미지 삭제](https://docs.docker.com/reference/cli/docker/image/rm/), [Container 조회](https://docs.docker.com/reference/cli/docker/container/ls/)

## OTP 발급 요청 제한

- 대상: 회원가입·비밀번호 재설정의 OTP 발급 POST 두 경로
  - `/bff/v2/auth/signup/email-otp`
  - `/bff/v2/auth/password-reset/email-otp`
  - Gateway 미경유 BFF의 Nginx 인입 제한, 두 용도의 공통 예산 사용
- 운영 전제: Resend 무료 티어의 하루 100건·월 3,000건
  - 초기 제한: 전체 분당 60건·순간 30건, 한 반 약 30명의 가입·재시도를 고려한 현재 단계의 기준
  - 무료 발송 한도는 전체 KDT 수강생 대상 운영에 부족, 전체 대상 운영 시 발송 요금제·한도 확대 필요
  - Nginx 요청 제한 완화와 Resend 발송 한도 확대의 구분, 발송 한도 소진 시 새 OTP 메일 발송 불가
  - 허용 요청도 초당 2건 속도로 분산, 최대 약 15초 대기 가능
  - 초당 2건은 보수적인 전송 기준, 실제 Resend 계정의 API Rate Limit 보장값 아님
  - Nginx 요청 수와 실제 메일 발송 수의 구분: 입력 오류·CSRF 거절도 제한 집계에 포함
  - 하루·월 사용량의 정확한 계수 기능 없음, 무료 한도는 Resend가 별도 적용
  - 지속 공격·다른 발송 경로까지 일일 예산 소진 방지 보장 없음
  - 일일 잔여량 예약·CAPTCHA 도입은 필요 시 별도 Identity·Frontend 작업
- 단순화 범위: IP·Host와 무관한 공통 제한 Key 사용
  - IP별 제한·사용자별 발송량 보장 없음, 한 사용자의 예산 소진 시 다른 사용자도 일시 차단
  - 기존 Network·IP Header 전달 방식 유지, OTP를 위한 전용 Network·고정 IP 추가 없음
  - Header의 사용자 IP 진위 검증 기능 아님, OTP 제한 판단에서 해당 Header 미사용
- 차단 응답: `429`·`Retry-After: 60`·`COMMON_TOO_MANY_REQUESTS`
  - 응답 Header·본문·Nginx 접근 Event의 동일 Request ID
  - 차단 요청의 Frontend 전달 없음, 일반 조회·다른 BFF·API 영향 없음
  - `Retry-After`는 재시도 권고 시간, 다른 사용자의 합산 요청에 따른 재차 차단 가능

### 연수생·관리자 사용 시 운영 기준

- 현재 목적: 소규모 서비스의 단순 남용 억제, 무료 발송량의 완전한 보호 기능 아님
- 학교 공인 IP 공유 여부와 무관하게 연수생·관리자 모두 같은 요청 예산 사용
  - 평상시 제한 유지, 429 발생 시 잠시 후 재시도 안내
  - 단체 가입 전 예상 인원·재발송 여유·Resend 잔여량 확인, 인원을 나눈 순차 가입 안내
- 정상 단체 가입의 반복 차단 시 해당 기간의 합산 제한 조정 후 기존 값 복원
  - 짧은 동시 요청은 `burst`, 지속 요청은 `rate` 조정 검토
  - Resend API 속도·일일/월간 발송 한도와 별개인 Nginx 제한, 제한 완화만으로 발송 한도 증가 불가
- 반복 남용이나 정상 이용량의 무료 한도 초과 시 별도 개선 검토
  - 남용: 계정·수신 주소별 제한 또는 CAPTCHA 검토
  - 정상 이용량 증가: 발송 요금제·운영 예산 검토
  - 현재 범위에서 추가 저장소·일일 사용량 집계·CAPTCHA 구현 없음

### 적용 확인

- 자동 검증: `bash tests/nginx-observability-test.sh`
  - 실제 Nginx·모의 Frontend로 정상 요청·두 용도의 합산 차단·IP/Host Header 변경과 무관한 제한 확인
  - Resend·학교 자원 호출 없음
- 운영 확인: 이용이 적은 시간의 통제된 검증
  - 본인 주소의 정상 발급 1건 확인, 다수 실제 메일 발송으로 부하 검증 금지
  - `{}` 본문·Cookie 없는 OTP POST로 입력/CSRF 거절과 최종 429 확인 가능
  - 잘못된 요청도 공통 예산 소비, 전체 사용자의 일시 제한 가능성 사전 안내
  - 응답의 `Retry-After`·Request ID와 Kibana의 동일 Nginx Event 확인
  - 대기 후 정상 발급·비밀번호 재설정 화면 재확인
  - Frontend PR #127 리뷰의 최종 해결 판단은 운영 경로 확인 뒤 진행
- 근거: [Resend 요금제](https://resend.com/pricing/), [계정 한도](https://resend.com/docs/knowledge-base/account-quotas-and-limits), [Nginx 요청 제한](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)

## 중앙 로그 착수 전 확인

```bash
bash ./scripts/observability-check.sh
```

- 실행 위치: 학교 서버의 Infra 저장소
- 입력: 제공받은 Elasticsearch URL·공용 사용자명·비밀번호
  - HTTP 주소: 학교 내부 보호망 여부의 명시적 확인
  - 사설 CA: 학교 CA를 신뢰하도록 설정 후 실행, `-k` 사용 금지
- 출력: 버전·필요 작업의 허용 여부·Data Node 수·팀 Data Stream 상태
- 미수행: 계정 생성·권한 변경·Index 생성·로그 조회·Telegram 전송
- 결과 해석
  - `403`: 해당 조회의 허용 여부 확인 필요, 새 계정 발급 전제 없음
  - `404`: 대상 부재 또는 해당 버전의 API 미지원
  - `true`: 계정에 부여된 권한의 조회 결과, 실제 쓰기 성공 보장 아님
  - 서버 Host에서의 접속 결과이며 Filebeat·ElastAlert2 Container 통신은 별도 검증
- 다음 확인
  - Kibana 화면의 버전
  - 운영 알림용 Bot·채팅방 선택
  - 팀 Template·보존 정책·실제 쓰기는 버전 확정 후 연결 단계에서 확인
- 확인값: 학교 Elasticsearch `8.19.3`·내부 주소 `http://10.116.64.14:9200`
- 운영 확인 `2026-09-07`: 일부 서비스의 중앙 로그 검색 확인, Rule·Nginx 수집과 Telegram 수신의 추가 확인 필요
- 적용 절차: [중앙 로그 운영](../observability/README.md)
  - 별도 `omagotchi-observability` 프로젝트, 앱 배포의 `--remove-orphans`와 분리
  - 기존 `PROD_ENV`의 관측 항목 세 개 추가, 앱의 필수 설정과 분리
  - 관측 항목 도입 이후의 일부·전체 누락 시 Runtime 설정 교체 중단
  - 초기화 Container에서 기존 팀 자원·조회 실패 확인 시 생성 중단
  - 수집 Label 반영과 Filebeat 수집 확인의 구분, 평상시 기동은 Infra 자동배포에 포함
  - 운영 알림 도입 시 `OPS_TELEGRAM_BOT_TOKEN`·`OPS_TELEGRAM_CHAT_ID` 추가
  - 알림 상태 저장소 최초 생성·기동·갱신은 Infra 자동배포: [Telegram 운영 절차](../observability/README.md#telegram-오류-알림)

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
- Nginx 접근 Event
  - 명령: `./scripts/compose.sh logs -f nginx`
  - 확인 대상: stdout의 `nginx.access` JSON
  - 중앙 수집·알림 대상
- Nginx 상세 오류
  - 명령: `./scripts/compose.sh exec -T --user root nginx tail -n 200 /var/log/nginx/error.log`
  - 저장 위치: 실행 중 Container의 Root 전용 10MB tmpfs
  - 복구 불가 시점: Container 재시작·재생성·비정상 종료
  - 10MB 소진 뒤 추가 기록 중단
  - 장기 보존·감사 로그 사용 금지
  - 원본 Request Line의 중앙 수집·Issue·PR·메신저 복사 금지
- Nginx Upstream 시간값
  - 필드: `nginx.upstream.*_time_seconds`
  - 미호출: `-`
  - 재시도: 복수 문자열 가능
  - 수치 집계 전 정규화 필요
- 단일 서비스 복구: `deploy.env`의 직전 SHA로 `deploy-service.sh` 실행
- Rule 복구: Script의 역순 복구 결과·A/B 역할 재확인
- 기존 `omagotchi-net` 소유 Label 경고: 실행 중 Network 제거 금지, 전체 중단이 가능한 정비 시간에 Compose Network 재생성
- Runtime 설정 동기화 실패: 기존 `prod.env` 유지 여부·후보 검증 오류·Infra Git 상태·공용 Lock 확인
- Runtime 설정 복구: `prod.env.previous`를 후보로 별도 검증한 뒤 `prod.env` 복원, 영향 서비스만 재배포
- 자동 재시도 금지: 원인·현재 실행 SHA·Eureka 등록 상태 확인 후 재실행
