# 중앙 로그·오류 알림 운영

## 현재 범위

- Docker stdout → Filebeat `8.19.3` → 학교 Elasticsearch `8.19.3` → Kibana
- 업무 서비스·배포와 분리된 `omagotchi-observability` Compose 프로젝트
- 별도 Logstash·학교 Kubernetes 사용 없음
- Elasticsearch 오류 Event → ElastAlert2 `2.31.0` → Telegram 운영 채팅방
- 메트릭·Collector·Tempo의 후속 적용
- 운영 확인 `2026-09-07`: Filebeat → Elasticsearch → Kibana의 일부 서비스 로그 수집 확인
  - 남은 확인: Rule Engine A/B·Nginx의 수집 Label 반영, 동일 Request ID 조회, Telegram 수신

## 수집·보존 경계

- Container 조건: `omagotchi` 프로젝트와 `co.elastic.logs/enabled=true` 동시 충족
  - Filebeat 탐색 조건의 프로젝트명: `docker.container.labels.com.docker.compose.project.value`
  - Compose의 `project`·`project.working_dir` 등 공존 시 원래 프로젝트명이 `.value`로 이동
  - Label 추가·변경의 반영에는 Container 재생성 필요, 단순 재시작으로 반영 불가
- Event 조건: stdout의 `nginx.access`·`*.http`·`*.error` JSON
- 중앙 전송: `filebeat/filebeat.yml`의 허용 필드만 보존
  - 안전한 요약·HTTP 상태·서비스 정보·Request ID·Trace ID 등
  - `@timestamp`: Filebeat 기본 보존, `include_fields` 목록에 중복 선언 금지
- 제외: 다른 팀·수집기·Cloudflared·일반 기동 로그·임의 업무 로그·`*.diagnostic`·stderr
- 원문 상세 조사: 기존 Docker `10MB × 3개` 순환 로그
  - Filebeat 탐색에 회전 파일 포함, Docker 보관 범위를 벗어난 로그 복구 불가
- Data Stream: `logs-omagotchi-prod` 한 개·Primary Shard 한 개
- ILM: `1일` 또는 Primary `1GB` Rollover, **Rollover 이후 3일** 경과한 Index 삭제
  - Event 발생 후 정확히 3일 삭제나 전체 저장 용량 상한을 뜻하지 않음
  - 실제 적용 전의 초기값 조정, 운영 중인 정책의 자동 변경 없음
  - Replica: 학교 기본값 유지, Data Node 한 개일 때 미할당 여부 확인
- Filebeat: CPU 0.5·Memory 256MiB·Disk Queue 512MB
  - Queue·Registry의 `filebeat-data` Volume 보존
  - Queue 상한과 별도로 Registry·Volume 전체 사용량 확인, Volume 자체의 강제 용량 제한 없음
  - 연결 장애의 제한된 완충, 무손실 전달 보장 아님
  - 재전송에 따른 중복 가능, 감사 로그·정확한 업무 건수의 기준으로 사용 금지
  - Mapping 거절: 재시도 없이 Drop 가능, 집계 로그와 로컬 거절 로그로 확인
- 수집량: Filebeat 전체의 접근 Event `20건/초`·오류 Event `5건/초`, 두 한도의 독립 적용
  - Container별 한도 아님, 서비스 간 공정 배분·오류 종류별 최소 수집 보장 없음
  - 제품의 Rate Limit 초과분 즉시 제외, 대기열 저장·나중 재전송 없음
  - 수집 처리 시각 기준, 밀린 로그 재처리·Container 재시작 시에도 일부 누락 가능
  - ES 전송 순간의 속도 제한 아님, Queue에 쌓인 Event는 복구 후 묶음 전송 가능
- 단일 로그: `message_max_bytes=16384`로 16KiB 제한
  - 초과 부분의 절단, 잘린 JSON의 중앙 수집 제외
  - Docker 원문은 기존 회전 범위에서만 확인 가능
- 접근 Event 누락에 따른 중앙 로그 기반 요청 수·오류율 계산 금지, 메트릭 수집 경로 사용

## 현재 운영의 보안 제약

- 학교 제공 HTTP·공용 `elastic` 계정 사용
  - 내부 IP 경로도 암호화된 통신은 아님, 인증 정보·로그의 전송 중 노출 위험
  - `elastic`은 Superuser, 계정 유출 시 팀 저장소 밖의 학교 공용 자원까지 영향 가능
  - 이번 구성의 별도 계정·TLS 도입 없음, 팀 자원만 다루는 코드가 계정 권한 자체를 제한하는 것은 아님
- Filebeat의 Docker Socket Mount 유지
  - `:ro`는 Docker API의 조회·변경 요청을 구분하는 권한 제한이 아님
  - Filebeat 침해 시 Docker Daemon을 통한 공유 Host 통제 가능성
  - 공식 이미지·버전 고정·Capability 제한만으로 해당 위험 제거 불가
  - Filebeat를 신뢰하는 운영 구성요소로 취급, 별도 Socket 접근 제어 Proxy는 이번 범위에서 제외

## 최초 적용 전 확인

1. Infra 변경의 검토·승격·서버 반영
   - 수집 허용 Label 추가에 따른 앱 Container 재생성 가능성
   - 기존 순차 배포 절차 유지, Filebeat의 자동 시작 없음
2. 읽기 전용 확인: `bash ./scripts/observability-check.sh`
   - URL: `http://10.116.64.14:9200`, 기존 공용 계정 사용
   - 연결 확인·초기화·알림 실행 모두 루트 URL만 허용, 끝의 `/` 유무는 무관
   - `/elasticsearch` 같은 하위 경로·Query·URL 내 인증 정보 사용 금지
   - 내부 경로 확인: `10.116.64.11` → `10.116.64.14`, `eno2`
   - HTTP의 암호화 없음, 인터넷 경유 주소로 대체 금지
   - Data Stream·Template·ILM의 최초 부재 확인
   - 기존 자원 존재·403·예상 밖 응답이면 아래 초기화 중단 후 결과 검토
   - Template 우선순위 250의 적합성 확인, 충돌 시 임의 증대 금지
3. 루트 `.env.prod.example`의 중앙 로그 Elasticsearch 세 항목을 기존 `production` Environment의 `PROD_ENV`에 추가
   - 기존 앱 설정 유지, 관측 항목만 추가 — 예시 세 줄로 `PROD_ENV` 전체 교체 금지
   - 새 Secret 공급원·새 학교 계정 생성 없음
   - 실제 비밀번호의 Git·Shell 명령 인자·채팅 기록 금지
   - 기존 설정 동기화 Workflow로 서버 `secrets/prod.env` 갱신
   - 기존 애플리케이션의 필수 환경변수에 관측 항목 추가 없음
   - 기존 파일·후보 파일 중 관측 항목이 있으면 관측 Compose도 교체 전에 검증
   - 관측 항목이 양쪽 모두 없으면 기존 앱 설정만 검증
   - 도입 이후 관측 항목의 일부·전체 누락 시 기존 운영본·복구본 보존
   - 설정 해석만 검증, ES 인증·통신 여부는 아래 연결 확인에서 검증
4. 서버 Docker Root Dir 확인: `docker info --format '{{.DockerRootDir}}'`
   - 현재 Mount 기준: `/var/lib/docker/containers`
   - 다른 경로이면 적용 전 Mount 수정, 존재하지 않는 빈 경로로 기동 금지

## 연결 확인

서버의 Infra 디렉터리에서 한 번에 실행:

```bash
bash -c '
set -e
./scripts/observability-compose.sh config --quiet
./scripts/observability-compose.sh run --rm --no-deps filebeat filebeat test output --strict.perms=false -e -E logging.level=warning
'
```

- 학교 Elasticsearch에 대한 실제 Container 인증·연결 확인
- Template·Index·문서 생성 없음
- `config` 원문 출력 금지, Secret을 숨기는 `--quiet` 사용

## 최초 초기화·수집 시작

- 실행 조건: 위 조회 결과의 검토 완료·팀 자원 부재·보존 정책 동의
- 자원 생성은 Filebeat 내장 `setup`에 위임, 사전 확인만 Shell Script에서 수행
- `scripts/observability-setup.sh`: 내장 `setup` 실행 전 연결·인증 및 기존 팀 자원 확인
  - 같은 이름의 Data Stream·Index·Alias, Index Template, ILM 중 하나라도 존재하면 중단
  - 자원 부재 응답 `404`만 허용, 인증 오류·권한 부족·연결 실패 시 중단
  - 조회 결과·비밀번호 원문 출력 및 자동 삭제 없음
  - 팀원 간 최초 초기화의 단독 실행, 조회 이후의 동시 생성까지 원자적으로 차단하는 기능은 아님
- 주의: 새 ILM을 만들 때 Template 갱신까지 수행하는 제품 동작
  - `overwrite: false`만으로 모든 기존 Template의 덮어쓰기 방지가 보장되지 않음
  - 기존 자원·부분 초기화가 있으면 재실행 대신 원인·현재 정책 검토
- 새 팀 자원만 생성: ILM `omagotchi-logs`, Template·Data Stream `logs-omagotchi-prod`
- 학교 기본 `filebeat-*` 자원·Kibana Dashboard 설치 없음

```bash
bash -c '
set -e
./scripts/observability-compose.sh run --rm --no-deps filebeat-setup
./scripts/observability-compose.sh up -d --no-deps filebeat
./scripts/observability-compose.sh ps
./scripts/observability-compose.sh logs --tail=50 --no-color filebeat
'
```

- 설정·초기화 실패 시 수집 시작 중단
- 기존 일반 Index와 이름 충돌 시 자동 삭제 금지
- Kibana 기존 [Omagotchi Space](http://s4.java21.net:5601/s/aiot3-team5-omagotchi/app/observabilityOnboarding) 유지
  - Space ID: `aiot3-team5-omagotchi`, Filebeat 전송 설정과 무관
  - Discover에서 Data View `logs-omagotchi-prod` 생성, 시간 필드 `@timestamp`
  - 최근 정상 요청 뒤 `http.request.id`·`trace.id`·`service.name` 검색
  - 오류 대표 Event 검색·진단 Event 및 민감 필드의 부재 확인
- 관찰: `libbeat.output.events.dropped`·Queue 적체·Container Memory·Data Stream 용량

## 초기 용량 확인·수집 중지 기준

- 팀 관측 Index의 초기 운영 예산: Replica 포함 색인 저장량 합계 `8GiB`
  - 학교 Cluster의 강제 Quota 아님, Translog·임시 파일 등 전체 Disk 사용량과 구분
  - 시작 1시간 후·24시간 후 확인, 이후 발생량에 따른 점검 주기 조정
  - 학교 Disk 부족·ILM 오류·예산 도달 시 Filebeat·ElastAlert2 중지 후 원인 확인
  - 원인 확인 전 보존 연장·수집량 증대·학교 전역 설정 변경 금지
- Kibana Dev Tools의 읽기 전용 조회
  - 팀 로그와 알림 상태만 조회, 다른 팀 Index 제외
  - `_all.total.store.size_in_bytes`: 두 종류 Index의 Primary·Replica 합계, `8GiB = 8589934592 bytes`
  - 조회 실패·누락된 값·실패 Shard의 0바이트 간주 금지

```http
GET /logs-omagotchi-prod,elastalert-omagotchi-status*/_stats/store?filter_path=_all.total.store.size_in_bytes,_shards.failed
GET /logs-omagotchi-prod,elastalert-omagotchi-status*/_ilm/explain?only_errors=true
```

- 중지 명령: `./scripts/observability-compose.sh stop filebeat elastalert`
  - 수집·알림만 중지, 기존 Index 자동 삭제·업무 서비스 중지 없음
  - 자동 용량 감시·삭제 Script 미도입, 현재 구성만으로 전체 용량 상한 보장 불가

## 설정 변경·복구

- 공개 Bind Mount 권한: 설정·Python 파일 `644`, Mount 디렉터리·Setup Script `755`
  - 전체 Infra 배포에서 이전 `umask 077`로 생성된 관측 파일의 권한 복구
  - Secret·JWT Key·`deploy.env` 권한 변경 없음, Container의 Capability 제한 유지
  - `--strict.perms=false`: Filebeat 자체 소유권 검사만 생략, 운영체제의 읽기 권한은 별도 필요
- 서버 임시 수정본의 배포 전 확인: `git diff -- observability/filebeat/filebeat.yml`
  - 서버에서 적용한 `.project.value` 수정의 보존·원격 반영 확인 후 작업 트리 정리
  - 다른 변경의 일괄 폐기 금지, 추적 파일 변경이 남으면 자동 배포 중단
- Filebeat 설정 변경: `./scripts/observability-compose.sh up -d --no-deps --force-recreate filebeat`
  - Bind Mount 파일 수정만으로 자동 재기동되지 않는 점 주의
- 수집 중지: `./scripts/observability-compose.sh stop filebeat`
- 최초 초기화가 끝난 뒤 `filebeat-setup` 재실행 금지, 수집기만 재생성
- Secret 교체: GitHub `PROD_ENV` 갱신 → `main`의 `Sync Runtime Configuration` 실행 → Filebeat 재생성
  - 관측 중지 시 접속 항목 유지, 항목 삭제를 통한 수집 중단 금지
- Queue·Registry 보존: 운영에서 `down --volumes` 금지
- 거절 상세 조회: `./scripts/observability-compose.sh exec --user root filebeat sh -c 'tail -n 20 /usr/share/filebeat/logs/rejected-events*'`
  - Root 전용 16MiB tmpfs·파일당 5MiB·최대 2개
  - Container 재생성 시 삭제, 영구 보관·중앙 재수집 제외
- Filebeat 중지 중에도 업무 서비스·Docker Log Rotation 유지
- Index·ILM·Template 삭제는 별도 판단, 수집 중지와 함께 자동 삭제 금지

## Telegram 오류 알림

### 구성·준비

- 활성화 조건: 중앙 오류 Event의 도착·민감 필드 제외 확인
- Bot 표시명 제안: `오마고치 운영 알림`
  - 사용자명 제안: `omagotchi_ops_bot`, BotFather에서 사용 가능 여부 확인
  - 기존 사용자 기능 Bot과 분리, 운영 전용 그룹에 추가
  - 발신 전용 구성, 별도 Webhook·Bot 애플리케이션 불필요
- 기존 `PROD_ENV`에 루트 `.env.prod.example`의 두 항목 추가
  - `OPS_TELEGRAM_BOT_TOKEN`: BotFather에서 받은 Token
  - `OPS_TELEGRAM_CHAT_ID`: 운영 그룹의 음수 Chat ID
  - 기존 앱·Elasticsearch 항목 유지, 실제 Token의 Git·채팅 기록 금지
  - 알림 미도입 시 두 항목 생략 가능, 도입 이후 누락·빈 값은 동기화 단계에서 차단
- 제품 기본 이미지의 자동 Index 초기화 미사용
  - `runtime.py`: 접속 환경변수 변환·실행 모드 분리
  - `bootstrap.py`: 기존 팀 자원 확인·제품 Mapping과 ILM 적용
  - `telegram_alert.py`: 허용 필드의 평문 전송·Timeout·인증 정보 보호
  - 조회·Cursor·재알림·재시도: ElastAlert2 기본 기능 사용

### 최초 적용

- 실행 위치: 변경이 반영된 서버의 Infra 디렉터리
- 선행 조건: `PROD_ENV` 동기화·중앙 오류 검색 확인·운영 그룹 준비
- 최초 생성 전 확인: 아래 이름의 기존 Index·Alias·Template·ILM 부재
  - `elastalert-omagotchi-status`와 `_status`·`_silence`·`_error`·`_past`의 다섯 Alias
  - 각 Alias 이름의 Template·`<Alias>-000001` 형식의 실제 Index
  - ILM `omagotchi-alert-state`
- 기존 자원·403·연결 실패 시 쓰기 시작 전 중단
  - 부분 생성 후 자동 삭제·덮어쓰기·재시도 금지, 현재 자원 확인 후 복구 판단
  - 다른 팀 Template과의 우선순위 충돌 시 임의 증대 금지
  - 초기화의 단독 실행, 동시 실행의 원자적 잠금 보장 없음

```bash
bash -c '
set -e
./scripts/observability-compose.sh --profile alerts config --quiet
./scripts/observability-compose.sh run --rm --no-deps elastalert-setup
./scripts/observability-compose.sh up -d --no-deps elastalert
./scripts/observability-compose.sh ps
./scripts/observability-compose.sh logs --tail=50 --no-color elastalert
'
```

- 최초 상태 생성에는 Telegram 전송 없음
- 알림 Container 시작·재시작의 조회 범위
  - 최초 시작 또는 마지막 조회 시각이 5분 이상 지난 경우: 최근 5분부터 조회
  - 마지막 조회 시각이 5분 미만 지난 경우: 저장된 시각부터 조회 재개
  - 예: 마지막 조회 후 20분 뒤 재시작 시 앞선 15분의 오류는 알림 대상에서 제외
  - 오래된 오류의 일괄 알림 대신 최근 오류 우선, 중단 구간의 전체 알림 복구 보장 없음
  - 알림 제외와 로그 삭제는 별개, 수집·보존된 오류의 Kibana 검색 가능
- 평상시 기동: 다섯 Alias의 쓰기 대상만 확인, 자동 Index 생성·초기화 없음
- 준비 실패: 잘못된 설정·기존 자원·누락된 Alias의 안전한 사유 안내
  - 인증 실패 `401`·작업 권한 부족 `403`·자원 부재 `404`의 구분
  - 외부 예외의 응답·URL·인증값 출력 제외
  - 생성 도중 실패 시 부분 생성 상태 확인, `elastalert-setup`의 무조건 재실행 금지
- Filebeat만 실행하는 기존 명령의 알림 Container 자동 기동 없음

### 알림·자원 경계

- 대상: `ERROR`·`*.error`·`http.server.request.failed`·`error.code` 존재
  - 일반 `5xx` 접근 로그·`WARN`·상세 진단 로그 제외
- 그룹: 서비스·오류 코드·오류 종류
  - 첫 대표 오류 한 건, 같은 그룹 10분 재알림 억제
  - 반복 지속 시 최대 1시간까지 재알림 간격 증가
  - 억제 건수 요약·모든 그룹 합계의 전역 전송량 상한 아님
- 메시지: 시각·서비스·오류 종류·안전한 요약·경로·Request ID·Trace ID·KQL·Space 링크
  - Stack Trace·Body·Cookie·Token 제외, Markdown/HTML 해석 없음
  - `message`는 앱의 안전한 요약 계약 전제, 임의 문자열의 자동 민감정보 판별 기능 아님
- 전송: HTTPS·Redirect 차단·연결 3초/읽기 5초 Timeout
  - 전송 실패 시 원본 URL·응답·예외 내용 미출력
  - 전송기 내부 재시도 없음, 제품 재시도 대상 기간 10분
  - Timeout 이후 재전송의 중복 가능, 정확히 한 번 전달 보장 없음
- 조회: 1분 주기·5분 지연 허용 구간·페이지당 100건·추가 Scroll 제한 5회·동시 Rule 1개
  - 제한 초과·5분을 넘는 수집 지연의 알림 누락 가능성
- 예상 밖 Rule 예외: 오류 기록 후 다음 1분 조회 주기의 실행 유지
  - `disable_rules_on_error: false`, 예외 한 번으로 Rule의 영구 중지 방지
  - 해당 회차의 완전한 재처리·무손실 보장 아님
  - 지속 실패는 중지·설정 수정 대상, 자체 무한 즉시 재시도 Loop 미사용
- Container: Memory 256MiB·CPU 0.5·tmpfs 16MiB·자체 로그 `10MB × 3개`
  - Host Port·Docker Socket·앱 Network 미사용
  - 억제 건별 INFO 로그 제외, 오류만 로컬 출력
- 상태 보존: 각 Alias의 `1일` 또는 Primary `100MB` Rollover·전환 이후 `3일` 삭제
  - Cursor·억제 상태·실패 알림의 무기한 누적 방지
  - 모든 상태 Index의 합계 용량 상한은 아님, 학교 ES 자원 제한과 별개
  - 짧은 재알림·재시도 기간을 넘는 상태 보존, 수동 장기 Silence 미지원

### 확인·중지

- 대표 오류 한 건의 Telegram 수신·KQL 검색 확인
- 동일 오류 반복 시 억제·다른 오류 코드의 별도 알림 확인
- 상태 Alias의 ILM 적용·용량 및 경고 로그 확인
- 알림이 오지 않을 때: `ps`만으로 정상 판정 금지
  1. Kibana에서 최근 `*.error` Event의 도착 확인
  2. `./scripts/observability-compose.sh logs --since=10m --tail=100 --no-color elastalert`로 전송·조회 오류 확인
  3. 반복되는 같은 내부 예외라면 아래 중지 명령 실행 후 설정·코드 원인 확인
  4. 수정 후 Container 재생성·새로운 대표 오류 한 건의 수신 확인
- 알림 중지: `./scripts/observability-compose.sh stop elastalert`
- 설정·Token 교체: `PROD_ENV` 동기화 후 `./scripts/observability-compose.sh up -d --no-deps --force-recreate elastalert`
  - 초기화 재실행 금지, 설정 중지 목적으로 Token 항목 삭제 금지
- 알림 장애 시 Filebeat·업무 서비스의 독립 실행 유지
- 로컬 검증: `./tests/elastalert-test.sh`
  - 외부 Network 없이 실제 제품 Rule 해석·팀 확장 검증
  - 실제 Bot Token의 통신·운영 그룹 수신은 별도 확인

## 근거

- [ElastAlert2 공식 Alerter 확장](https://elastalert2.readthedocs.io/en/latest/recipes/adding_alerts.html)
- [ElastAlert2 2.31.0 Telegram 전송기](https://github.com/jertel/elastalert2/blob/elastalert2-2.31.0/elastalert/alerters/telegram.py)
- [ElastAlert2 2.31.0 상태 Mapping·초기화](https://github.com/jertel/elastalert2/blob/elastalert2-2.31.0/elastalert/create_index.py)
- [ElastAlert2 2.31.0 재시작 조회 범위](https://github.com/jertel/elastalert2/blob/elastalert2-2.31.0/elastalert/elastalert.py)

- [Filebeat 8.19 JSON Template](https://www.elastic.co/guide/en/beats/filebeat/8.19/configuration-template.html)
- [Filebeat 8.19 Elasticsearch Output](https://www.elastic.co/guide/en/beats/filebeat/8.19/elasticsearch-output.html)
- [Filebeat 8.19 Rate Limit의 초과 Event 제외](https://www.elastic.co/guide/en/beats/filebeat/8.19/rate-limit.html)
- [Filebeat 8.19 JSON Field 해석](https://www.elastic.co/guide/en/beats/filebeat/8.19/decode-json-fields.html)
- [Filebeat 8.19 Filestream 메시지 크기 제한](https://www.elastic.co/guide/en/beats/filebeat/8.19/filebeat-input-filestream.html#_message_max_bytes)
- [Filebeat 8.19.3 전역 Processor 공유](https://github.com/elastic/beats/blob/v8.19.3/libbeat/publisher/processing/default.go)
- [ElastAlert2 Rule 예외 처리](https://elastalert2.readthedocs.io/en/latest/configuration.html)
- [Elasticsearch 8.19 Index 저장량 조회](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/indices-stats.html)
- [Filebeat 8.19.3 Docker 라벨 조건 처리](https://github.com/elastic/beats/blob/v8.19.3/libbeat/autodiscover/providers/docker/docker.go)
- [Filebeat 8.19.3 ILM·Template 초기화 순서](https://github.com/elastic/beats/blob/v8.19.3/libbeat/idxmgmt/index_support.go)
- [Elasticsearch 8.19 Data Stream·Index·Alias 존재 조회](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/indices-exists.html)
- [Elasticsearch 8.19 Index Template 조회](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/indices-get-template.html)
- [Filebeat 8.19 거절 Event 로그](https://www.elastic.co/guide/en/beats/filebeat/8.19/configuration-logging.html#_configuration_options_for_event_data_logger)
- [Filebeat 8.19 Log Rotation](https://www.elastic.co/guide/en/beats/filebeat/8.19/file-log-rotation.html)
