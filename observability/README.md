# 중앙 로그 운영

## 현재 범위

- Docker stdout → Filebeat `8.19.3` → 학교 Elasticsearch `8.19.3` → Kibana
- 업무 서비스·배포와 분리된 `omagotchi-observability` Compose 프로젝트
- 별도 Logstash·학교 Kubernetes 사용 없음
- Telegram·메트릭·Collector·Tempo의 후속 적용
- 현재 상태: 로컬 검증용 구성·운영 미적용

## 수집·보존 경계

- Container 조건: `omagotchi` 프로젝트와 `co.elastic.logs/enabled=true` 동시 충족
- Event 조건: stdout의 `nginx.access`·`*.http`·`*.error` JSON
- 중앙 전송: `filebeat/filebeat.yml`의 허용 필드만 보존
  - 안전한 요약·HTTP 상태·서비스 정보·Request ID·Trace ID 등
  - `@timestamp`: Filebeat 기본 보존, `include_fields` 목록에 중복 선언 금지
- 제외: 다른 팀·수집기·Cloudflared·일반 기동 로그·임의 업무 로그·`*.diagnostic`·stderr
- 원문 상세 조사: 기존 Docker `10MB × 3개` 순환 로그
  - Filebeat 탐색에 회전 파일 포함, Docker 보관 범위를 벗어난 로그 복구 불가
- Data Stream: `logs-omagotchi-prod` 한 개·Primary Shard 한 개
- ILM: `1일` 또는 `5GB` Rollover, **Rollover 이후 7일** 경과한 Index 삭제
  - Event 발생 후 정확히 7일 삭제나 전체 저장 용량 상한을 뜻하지 않음
  - Replica: 학교 기본값 유지, Data Node 한 개일 때 미할당 여부 확인
- Filebeat: Memory 256MiB·Disk Queue 512MB
  - Queue·Registry의 `filebeat-data` Volume 보존
  - 연결 장애의 제한된 완충, 무손실 전달 보장 아님
  - 재전송에 따른 중복 가능, 감사 로그·정확한 업무 건수의 기준으로 사용 금지
  - Mapping 거절: 재시도 없이 Drop 가능, 집계 로그와 로컬 거절 로그로 확인

## 최초 적용 전 확인

1. Infra 변경의 검토·승격·서버 반영
   - 수집 허용 Label 추가에 따른 앱 Container 재생성 가능성
   - 기존 순차 배포 절차 유지, Filebeat의 자동 시작 없음
2. 읽기 전용 확인: `bash ./scripts/observability-check.sh`
   - URL: `http://10.116.64.14:9200`, 기존 공용 계정 사용
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

## 설정 변경·복구

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

## 근거

- [Filebeat 8.19 JSON Template](https://www.elastic.co/guide/en/beats/filebeat/8.19/configuration-template.html)
- [Filebeat 8.19 Elasticsearch Output](https://www.elastic.co/guide/en/beats/filebeat/8.19/elasticsearch-output.html)
- [Filebeat 8.19.3 Docker 라벨 조건 처리](https://github.com/elastic/beats/blob/v8.19.3/libbeat/autodiscover/providers/docker/docker.go)
- [Filebeat 8.19.3 ILM·Template 초기화 순서](https://github.com/elastic/beats/blob/v8.19.3/libbeat/idxmgmt/index_support.go)
- [Elasticsearch 8.19 Data Stream·Index·Alias 존재 조회](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/indices-exists.html)
- [Elasticsearch 8.19 Index Template 조회](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/indices-get-template.html)
- [Filebeat 8.19 거절 Event 로그](https://www.elastic.co/guide/en/beats/filebeat/8.19/configuration-logging.html#_configuration_options_for_event_data_logger)
- [Filebeat 8.19 Log Rotation](https://www.elastic.co/guide/en/beats/filebeat/8.19/file-log-rotation.html)
