# 메트릭·주요 Span 수집 운영

> 상태: Infra 구현·로컬 검증, 서비스 계측 연결·운영 검증 전 · 기준일: 2026-09-07

## 이번 변경과 남은 작업

- 이번 변경: Prometheus·Grafana·Collector·Tempo 설정, 주요 Span 수집·정제, 조회·증상 알림의 기본 구성
- 변경 제외: 서비스 의존성·계측·Export·보안 설정·업무 로직, Broker Context 전파, 무중단 배포
- 현재 서비스 상태
  - Spring: Prometheus Registry·OTLP Exporter 미추가, 수집 Endpoint·Export 설정 미완료
  - Prediction: `/metrics` 계약·Prometheus Client·OTLP Exporter 미추가
  - 기존 Request ID·W3C 전파와 실제 메트릭·Span 저장의 구분
- 순서: 이번 Infra PR의 dev·main 반영 → Infra 도구 확인 → 서비스 계측·Export 묶음 작업 → 실제 Dashboard·Waterfall 확인
- 완료 판정: 도구 기동만으로 완료 처리 금지, 아래 서비스 연결·검증 포함

## 구성과 파일

| 경로 | 역할 |
|---|---|
| `compose.yaml` | 별도 Compose 프로젝트·선택 Profile·자원·네트워크 제한 |
| `prometheus/prometheus.yml` | 앱 Endpoint와 도구 자체 지표의 15초 수집 |
| `prometheus/http-rules.yml` | 서비스·경로별 HTTP 증가량·오류율·증상 판정 |
| `grafana/provisioning/` | Data Source·Dashboard·Alert·Telegram 정책 등록 |
| `grafana/dashboards/http-overview.json` | 수집 상태·HTTP Rate·5xx·p95·JVM·CPU 조회 |
| `otel-collector/config.yaml` | OTLP/HTTP 수신·정제·제한된 재전송 |
| `tempo/config.yaml` | 단일 Process·Local Volume의 Trace 저장 |

- 정확한 Image: Prometheus `v3.13.2` LTS, Grafana `13.2.1`, Collector Contrib `0.160.0`, Tempo `3.0.3`
- 선택 기준: 기존 제품·버전 유지, 신규 도구 추가 없음
- Collector의 버전 종속 옵션: `--feature-gates=ottl.set.allowNil`
  - `0.160.0`의 Alpha 옵션, `set(span.events, nil)`·`set(span.links, nil)` 초기화에 필요
  - 선택 이유: Link 포함 Span의 통째 삭제 대신 부가 정보만 제거, 부모·자식 관계 보존
  - 생략 시 `set(..., nil)`의 무시 가능, Compose와 동일한 옵션으로 실행·검증 필요
  - 버전 변경 시 옵션 상태·정제 Fixture 재검증, Image만 단독 교체 금지
- 프로젝트: 기존 `omagotchi-observability`
  - `metrics`: Prometheus·Grafana
  - `tracing`: Collector·Tempo
  - 기존 Filebeat 명령으로 새 도구의 자동 기동 없음
- 앱 Network `omagotchi-net`: Prometheus Scrape·Collector OTLP 수신만 참여
- 관측 전용 Network: Prometheus·Grafana·Collector·Tempo 연결
  - Data Source: `http://prometheus:9090`, `http://tempo:3200`
  - 앱 Export: `http://omagotchi-otel-collector:4318/v1/traces`
  - Collector → Tempo: `tempo:4317`
- 유일한 Host Port: Grafana `127.0.0.1:13000`
  - SSH Tunnel 전용, Nginx·Cloudflare Route 추가 없음
  - 학교 공유 Network 내부 도구 간 인증·TLS 없음, 별도 보안 경계로 간주 금지
- 미도입: Logstash·Kafka·Object Storage·Node Exporter·cAdvisor·Metrics Generator·Tail Sampling

## 자원·보존

| 도구 | Memory 상한 | CPU 상한 | 저장·처리 제한 |
|---|---:|---:|---|
| Prometheus | 512MiB | 0.5 | TSDB 7일·2GB, Query 동시 4개·15초 |
| Grafana | 512MiB | 0.5 | Dashboard·설정 DB 전용 Volume, 추가 Plugin 자동 설치 없음 |
| Collector | 384MiB | 0.5 | Memory Limiter 256MiB, Queue 16MiB·전송 동시 2개·재시도 최대 30초 |
| Tempo | 4GiB | 1 | 72시간, 수신 256KiB/초·Burst 512KiB, Trace당 1MiB·동시 Query 2개 |

- 신규 Memory 상한 합계: 약 5.4GiB, 기존 앱·Filebeat·ElastAlert2 사용량과 별도
- Grafana 예산 조정: macOS 첫 기동 RSS 약 320MiB 확인, 기존 256MiB 계획에서 512MiB로 증액
  - Go Memory 목표 384MiB, Linux Container의 안정 기동·부하 보장값은 아님
- 모든 도구의 자체 Docker 로그: `10MB × 3개`, 읽기 전용 Root Filesystem
- Volume 전체의 강제 Disk Quota 없음
  - Prometheus 2GB: WAL·Head도 사용량 계산에 포함, 용량 정리 시 보존 Block만 삭제
    - WAL·Head 자체와 Compaction 임시 공간까지 제한하는 전체 Volume 상한 아님
  - Tempo 72시간: 시간 보존, 합계 4GiB 제한 아님
    - 수신 256KiB/초의 72시간 연속 유입량은 약 63.3GiB, Disk 예산 4GiB의 보장값 아님
    - 실제 저장량은 압축률·WAL·Compaction에 따라 변동, 위 수치는 Disk 사용량 예측 아님
  - Tempo 초기 Disk 예산 4GiB 초과·Host 여유 부족 시 Trace Export 축소 또는 중지 후 원인 확인
  - 수집 지연·Queue 초과·재시도 종료·Tempo 제한의 Span 유실 가능, 업무 감사 자료로 사용 금지
- 센서 계측의 Export 전제
  - InfluxDB 센서 데이터·Docker 처리 로그·Tempo Span의 저장 경로 구분
  - 센서 건수·건당 Span 수·Sampling에 따른 유입량과 Volume 증가량 확인 후 활성화
  - 현재 수신 제한·시간 보존만으로 공유 Host의 Disk 보호 완료 판정 금지
  - 강제 총량 제한이 필요하면 별도 저장 영역의 Quota 지원 확인, 운영 중인 Block·WAL의 임의 파일 삭제 금지
  - 근거: [Tempo 3.0.3 설정](https://github.com/grafana/tempo/blob/v3.0.3/docs/sources/tempo/configuration/_index.md), [Prometheus 저장 제한](https://prometheus.io/docs/prometheus/latest/storage/)
- Prometheus Endpoint 제한: 응답 5MB·Sample 10,000개·Label 30개
  - 초과 시 해당 Scrape 실패, 앞부분만 저장하는 기능 아님
  - 정상 Endpoint가 제한에 걸리면 Series 증가 원인 확인 후 상한 조정
- 첫 운영 확인: 기동 직후·1시간·24시간의 Memory·Disk·Drop 기록
  - 기존 학교 서버의 과거 여유 메모리만으로 현재 배포 여유 판단 금지

## Dashboard·알림 해석

- Dashboard 상태: 서비스 계측 연결 전 초안
  - 서비스·경로 필터, HTTP p95는 Histogram 노출 이후 표시
  - JVM·CPU·Endpoint 상태에는 서비스 필터만 적용
  - Prediction HTTP Metric 이름·Label 확정 전 Spring HTTP 집계에 합산하지 않음
  - 수집 없음과 정상 `0`의 구분, 빈 그래프의 정상 판정 금지
- HTTP 집계: 서비스별 요청, 내부 서비스 호출 포함
  - 여러 서비스의 건수를 합쳐 외부 사용자 요청 수로 표현 금지
  - Route: Framework Template 또는 정해진 Fallback, 원본 URL·ID 금지
  - SSE: 완료된 연결의 전체 소요 시간 포함, 일반 API 비교 시 경로 분리
- 증상 알림 1개
  - 서비스·경로별 5분간 `5xx` 5건 이상·오류율 5% 이상의 5분 지속
  - 첫 발송 대기 30초, 묶음 갱신 10분, 반복 4시간, 복구 알림 허용
  - 정상·저트래픽 `0`, 수집 자체가 없으면 `NoData`
  - `DatasourceNoData`·`DatasourceError`: 화면 상태 유지·Telegram만 상시 음소거
  - 개별 Container Down·배포 실패·학교 자원 장애·지연·CPU 알림 미추가
- Telegram: 기존 `OPS_TELEGRAM_BOT_TOKEN`·`OPS_TELEGRAM_CHAT_ID` 재사용
  - `[증상]`·상태·서비스·정규화 경로·판정 기준만 전송, HTML 해석 없음
  - ElastAlert2의 `[오류]` 상세 알림과 독립, 같은 장애의 두 알림 수신 가능
  - 전체 Label·Annotation·예외 원문의 일괄 전송 금지

## Collector 정제 경계

- 수집 원칙: HTTP 여부·Link 유무로 Span 자체를 삭제하지 않는 방식
  - Trace ID·Span ID·Parent Span ID·Kind·시간·상태 보존
  - 미분류 Span도 `Internal`·`Client` 등 Kind 이름으로 보존, 임의 원본 이름은 제거
  - 수집량 조절은 서비스의 요청·작업 단위 Sampling 우선, 수집된 Trace 중간의 종류별 삭제 지양
- 허용 속성: 서비스 정보와 아래의 제한된 호출 정보, 정확한 Key 목록은 `otel-collector/config.yaml` 기준

| 대상 | 보존 정보 | 표시 이름 |
|---|---|---|
| HTTP | Method·상태·Route Template·호출 대상 | 검증된 Method 또는 `HTTP` |
| JDBC·InfluxDB | DB 종류·작업 종류·Collection·정제된 쿼리 요약 | `DB` |
| Redis | DB 종류·명령 종류 | `Redis` |
| RabbitMQ 등 Messaging | 시스템·발행/소비 작업·고정 목적지 이름 | `Messaging` |
| AI 모델·도구 | 모델·작업·도구 이름·토큰 사용량 | `AI`·`AI tool` |
| 수동 업무 계측 | 합의된 고정 작업 이름 | 아래 허용 이름 |

- 수동 Span 이름: `prediction.inference`, `sensor.process`, `influxdb.query`, `influxdb.write`, `storage.upload`, `storage.download`, `job.execute`
  - 후속 서비스 작업의 이름 계약, 해당 Span의 생성·Export 구현 완료를 뜻하지 않음
  - 사용자·장치·파일·작업 ID를 이름에 붙이지 않는 방식
- 제거: 원본 URL·Query·Header·SQL 본문·바인딩 값·Redis Key/Value·AI 대화·도구 입력/결과·메시지 본문·임의 속성
  - Scope 속성뿐 아니라 이름·버전도 제거
  - Status Message·Tracestate·Span Event·Span Link 제거
- Link와 Parent 관계의 구분
  - Link 목록만 초기화, Link를 가진 Span과 Parent Span ID는 보존
  - 별도 Trace·배치 메시지를 연결하는 Link 관계의 조회 불가
  - 후속 RabbitMQ 작업에서 실제 Parent 전파·재시도 검증, Link가 필수인 흐름은 별도 정책 검토
- 쿼리 조회의 제한
  - `db.query.summary`: 애플리케이션에서 값 제거를 마친 요약만 전달
  - 원본 `db.query.text`·`db.statement`·`jdbc.query[*]` 미저장
  - 반복 요약·호출 수·시간은 N+1 의심 구간의 근거, 서로 다른 SQL의 동일 요약 가능성
  - 실제 N+1 판정·수정은 해당 조회 코드와 통제된 쿼리 수 검증으로 분리
- 정제 실패: 해당 Payload 거절, 원문을 그대로 Tempo에 전달하지 않음
- `error` 수준의 Collector 자체 로그, 원본 Context를 노출하는 Debug Exporter·Debug Logging 미사용
- 허용 필드 값까지 임의 비밀값을 판별하는 보안 장치 아님
  - 앱에서 URL·예외 원문 제거 우선
  - 서비스명·Route·쿼리 요약·목적지·모델·도구 이름에 안전한 값 사용
  - 운영 Export 전 각 SDK의 가짜 비밀값 테스트 필요

## 최초 적용

### 1. 배포 전 확인

- Fix 운영 확인: Rule Engine A/B·Nginx의 수집 Label 및 Kibana 동일 Request ID 조회
- Infra 변경의 검토·승격, 관측 도구의 자동 시작 없음
- `GRAFANA_ADMIN_PASSWORD` 한 항목만 기존 `PROD_ENV`에 추가 후 설정 동기화
  - 기본 로그인 ID: `omagotchi-admin`
  - 예시 비밀번호 사용 금지, 기존 앱·Elastic·Telegram 설정 유지
  - 도입 이후 비밀번호·Bot 설정 누락 시 기존 설정 보존 후 동기화 중단
  - Grafana 초기 관리자 비밀번호는 DB 최초 생성 시 적용
  - 기존 관리자 비밀번호 교체: Grafana에서 변경 후 관리값 갱신, Env 교체만으로 DB 비밀번호 변경 불가
- 서버 Infra 디렉터리에서 읽기 전용 확인:

```bash
bash -c '
set -euo pipefail
free -h
df -h . /var/lib/docker
docker stats --no-stream
ss -ltn | grep -E ":13000[[:space:]]" || true
./scripts/observability-compose.sh --profile metrics --profile tracing config --quiet
'
```

- `13000` 사용 중이면 기존 Process 종료 금지, 포트 충돌 해소 후 진행
- `config`의 전체 출력·`docker inspect` Env 출력 금지, Secret 노출 방지

### 2. 도구 기동

- 학교 서버에서 위 사전 확인·Secret 동기화 완료 후 실행
- 첫 명령은 Image 다운로드·Container 생성, 서비스 업무 Container의 재생성 없음
- Grafana 시작 시 기존 Telegram 정책도 등록, 실제 서비스 증상 조건 충족 시 전송 가능

```bash
bash -c '
set -euo pipefail
./scripts/observability-compose.sh --profile metrics --profile tracing pull prometheus grafana otel-collector tempo
./scripts/observability-compose.sh --profile metrics --profile tracing up -d --no-deps prometheus grafana otel-collector tempo
./scripts/observability-compose.sh --profile metrics --profile tracing ps
./scripts/observability-compose.sh --profile metrics --profile tracing logs --since=5m --tail=50 --no-color prometheus grafana otel-collector tempo
curl --disable --fail --silent --show-error --max-time 5 http://127.0.0.1:13000/api/health
'
```

- 로컬 PC: `ssh -N -L 13000:127.0.0.1:13000 <기존 SSH 접속 대상>`
- 브라우저: `http://127.0.0.1:13000`, 로그인 후 Omagotchi Folder 확인
- Data Source 연결 확인, Tempo 조회·Grafana 등록만으로 앱 Trace 수집 완료 판정 금지

### 3. 서비스 연결

- 작업 시점: 이번 Infra PR의 main 반영 후, 서비스 저장소별 독립 PR의 한 작업 묶음
- 범위: 기존 HTTP + JDBC·Redis·AI 우선, RabbitMQ·센서 처리의 별도 검증 단위
  - Identity·Learning: JDBC 쿼리 계측, 실제 SQL 값과 정제된 요약의 구분
  - Redis 사용 서비스: 기존 Boot·Lettuce 자동 구성 활용 여부 확인
  - Learning: 직접 생성하는 AI 모델·ChatClient의 ObservationRegistry 연결, 대화·도구 원문 미수집
  - Rule·Learning: RabbitTemplate·Listener 계측과 Header 전파, Retry·DLQ 경계 확인
  - InfluxDB·MinIO·외부 API: SDK 계측 여부 확인 후 필요한 호출 경계만 보완, 같은 호출의 중복 Span 방지
  - Prediction: 기존 Provider에 Export 연결, 실제 추론 구간만 작은 수동 Span 추가
  - 기존 Rule 업무 로직·`pipeline.correlation.id`·Message Payload 형식 변경 제외
- Spring: 기존 Micrometer Tracing 유지, Registry·OTLP Exporter의 Boot BOM 관리 버전 사용
  - `/actuator/prometheus`의 내부 노출·Spring Security 허용, 외부 Nginx/Gateway 차단 확인
  - HTTP Histogram·Route Label·서비스명 확인, 고유 사용자·Request ID Label 금지
  - OTLP/HTTP Endpoint·제한된 비동기 Export·Timeout·Sampling 설정
  - URL·예외·Baggage 원문 미전송 및 Collector 중지 중 업무 정상 확인
- Prediction: 기존 OTel Provider 재사용, 중복 계측·Provider 추가 금지
  - `/metrics` 이름·단위·Label 결정 후 Scrape Allowlist·Dashboard·Alert 수정
  - SSE 전체 연결 시간과 일반 응답 시간의 구분
- 순서: Gateway·Rule 한 경로 → 나머지 Spring 서비스 → Prediction
- 이 단계의 정확한 Property·보안 코드는 각 서비스 변경에서 검증, 이번 Infra 완료에 포함하지 않음

### 4. 완료 확인·중지

- 메트릭: 대상 `UP`·Route Template·실제 건수/5xx/지연·Histogram 확인
- 알림: 통제된 오류·정상화·수집 중지의 발송/복구/음소거 확인, 운영에 무작위 오류 유발 금지
- Trace: 동일 Trace ID·상이한 Span ID·Parent 관계·서비스 간 Waterfall·가짜 민감정보 부재 확인
- 장애 격리: 도구 중지 중 업무 요청 정상, 재기동 후 새 데이터 수집 재개
- 중지: `./scripts/observability-compose.sh stop prometheus grafana otel-collector tempo`
  - Filebeat·ElastAlert2 유지, Named Volume 보존
  - 앱 Export 활성화 후에는 앱 Export 비활성화 병행, SDK Queue 유실 가능
  - `down -v`·Volume 강제 삭제·파일 직접 삭제로 용량 조절 금지
- 설정 수정: `promtool`·Collector 검증 후 해당 도구만 재생성, 실패 시 검토된 이전 설정 복원

## 검증 범위

- `tests/telemetry-config-test.sh`: 실제 Promtool 설정·HTTP 집계 Fixture·Collector·Tempo 설정 검사
  - Promtool 평가용 `/tmp`만 64MiB 쓰기 허용, 설정·Fixture의 읽기 전용 유지
  - Tempo `-config.verify=true`: 고정 버전의 설정 해석·유효성 검사, Container 기동·저장 검증과 구분
- `tests/collector-privacy-test.sh`: HTTP·미분류 Internal·DB·Redis·AI·Tool·Messaging·수동 Span 입력
  - Span 개수·ID·Kind·시간·Parent 관계 보존, 종류별 이름·허용 속성 확인
  - Scope 이름·버전, URL·SQL·대화·메시지·Event·Link의 가짜 민감정보 제거
- `tests/runtime-config-sync-test.sh`: Grafana 비밀번호 누락·빈 값의 거절, 기존 운영본·복구본 보존과 후보 파일 삭제
- Promtool·Collector의 공식 Native Binary 사용 가능: `PROMTOOL_BIN`·`OTELCOL_BIN`, Image와 같은 고정 버전 필요
  - Tempo 설정 검사는 Docker Image 사용
- PR·배포 Workflow의 검증 제한: 모두 10분, 고정 버전 이미지 다운로드 시간 포함
- 로컬 Docker의 Linux Container 확인
  - 설정된 자원 제한으로 Prometheus·Grafana·Collector·Tempo 기동
  - Grafana Data Source 2개·Dashboard 9개 Panel·Alert·Contact Point·Policy·Mute 등록
  - 합성 HTTP Span의 Collector → Tempo 저장·조회, 가짜 민감정보 제거·부모/자식 관계 보존
  - Tempo 재시작 후 같은 Trace 조회
  - 별도 프로젝트·새 Volume·가짜 Token 사용, Alert 평가 비활성화·외부 통신 차단
- 미검증: 실제 서비스 Endpoint·Export 연결, 실데이터 Dashboard·서비스 간 Waterfall·운영 Telegram
  - 로컬 기동·합성 데이터 검증과 운영 부하·장기 자원 사용량 검증의 구분

## 공식 근거

- [Prometheus 3.13.2](https://github.com/prometheus/prometheus/releases/tag/v3.13.2), [저장소 보존](https://prometheus.io/docs/prometheus/latest/storage/)
- [Grafana 13.2.1](https://github.com/grafana/grafana/releases/tag/v13.2.1), [Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Collector 0.160.0](https://github.com/open-telemetry/opentelemetry-collector-releases/releases/tag/v0.160.0), [Filter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.160.0/processor/filterprocessor), [Transform](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.160.0/processor/transformprocessor)
- [OTTL 목록 초기화](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.160.0/pkg/ottl/contexts/internal/ctxutil/slice.go), [nil 대입 옵션](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.160.0/pkg/ottl/internal/metadata/generated_feature_gates.go)
- [Tempo 3.0.3](https://github.com/grafana/tempo/releases/tag/v3.0.3), [Tempo 설정](https://grafana.com/docs/tempo/latest/configuration/), [3.0.3 보존·제한 설정 구조](https://github.com/grafana/tempo/blob/v3.0.3/modules/overrides/config.go)
