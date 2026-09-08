# Grafana 브라우저 접속 설정

- 목적: SSH 터널 없이 팀원이 브라우저에서 모니터링 화면 조회
- 접속 주소: [Grafana](https://grafana.omagotchi.site)
- 적용 조건: 이 변경의 Infra 배포와 아래 Cloudflare 설정 완료
  - 저장소 수정만으로 도메인 연결·접근 제한의 자동 등록 없음
- 접속 순서: 팀원 이메일 확인 → Grafana 로그인 → 대시보드·Tempo 조회

## 1. 변경 범위

- 기존 Cloudflare Tunnel 재사용, 새 Tunnel·Token·서버 포트 불필요
- `cloudflared`와 Grafana의 전용 연결: `omagotchi-grafana-net`
  - 업무 Compose에서 생성, 관측 Compose에서 재사용
  - Grafana와 기존 관측 도구의 내부 연결 유지
- Grafana의 외부 주소와 HTTPS 전용 로그인 쿠키 설정
  - 브라우저부터 Cloudflare까지 HTTPS, Tunnel에서 Grafana까지 내부 HTTP
  - Grafana 익명 접근·자가 회원가입 비활성화 유지
- Prometheus·Tempo·Collector의 외부 도메인·공개 포트 추가 없음
- 업무용 `omagotchi.site` → Nginx 경로의 변경 없음
- 서버의 `127.0.0.1:13000` 유지: 내부 준비 점검용
  - 평소 로그인은 HTTPS 주소 사용, HTTP SSH 터널을 로그인 경로로 사용하지 않는 구성

## 2. Cloudflare Access 설정부터 진행

- 작업 위치: `omagotchi.site`와 기존 Tunnel을 관리하는 Cloudflare 계정의 `Zero Trust`
- Access: 허용한 사람만 Grafana 앞까지 들어오도록 확인하는 출입문
  - 학교 공인 IP 대신 팀원별 이메일 주소 사용
  - 이 이메일 확인과 Grafana 계정 로그인은 별도 절차
- 로그인 수단 준비
  - `Integrations` → `Identity providers` → `Add new identity provider` → `One-time PIN`
  - 이미 등록된 경우 재사용, 허용 이메일로 받은 코드로 로그인
  - 기존 Google 등 로그인 수단 사용도 가능, 아래 이메일 허용 목록은 동일하게 유지
- `Access controls` → `Applications` → `Create new application`
  - 유형: `Self-hosted and private`
  - 공개 주소 등록: `Add public hostname`, 사설 IP·사설 호스트 항목과 구분

| 항목 | 설정 |
|---|---|
| 이름 | `Omagotchi Grafana` |
| Subdomain | `grafana` |
| Domain | `omagotchi.site` |
| Path | 빈 값, 모든 Grafana 경로 보호 |
| Session duration | 초기 운영값 `8 hours` |
| Policy action | `Allow` |
| Include → Emails | 접속할 팀원들의 정확한 이메일 주소 |
| Login methods | 앞에서 준비한 `One-time PIN` 또는 기존 로그인 수단 |

- `Everyone`·`Bypass` 정책 추가 금지
  - `gmail.com` 전체 허용이나 로그인 수단만 지정한 허용 정책도 제외
- 저장 후 Application의 `AUD` 값과 Zero Trust의 `Team name` 확인
  - `AUD`: 이 Access Application의 식별값
  - `Team name`: `<이름>.cloudflareaccess.com`의 앞부분, 학교 서버 계정·Grafana 계정과 무관
- 공개 Route보다 Access Application의 선행 생성. [Cloudflare 설정 순서](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)

## 3. Infra 배포

- 평소 순서: 이 Infra 변경의 `dev` PR → `main` 승격 → 자동배포 성공 확인
- 기존 `PROD_ENV`·`GRAFANA_ADMIN_PASSWORD`·Tunnel Token 유지, 새 Secret 추가 없음
- 전체 배포의 cloudflared 기동에서 전용 Network 생성, 이후 Grafana 연결
  - Grafana만 먼저 수동 기동하면 외부 Network 부재로 실패 가능
  - 서버에서 임의 Network 생성·Container 수동 연결 대신 전체 배포 사용
- 성공 기준: 업무 Smoke Test와 관측 도구 준비 점검 통과
  - 자동배포 점검은 내부 HTTP 확인, Cloudflare 로그인 성공과 별도

## 4. 기존 Tunnel에 Grafana 주소 추가

- `Networking` → `Tunnels` → 현재 업무용 Tunnel → `Routes` → `Add route`
  - 유형: `Published application`
  - 화면에 따라 기존 `Public Hostnames` 메뉴명으로 표시 가능
  - 기존 업무용 Route의 수정·삭제 없이 항목 한 개 추가

| 항목 | 설정 |
|---|---|
| Subdomain | `grafana` |
| Domain | `omagotchi.site` |
| Path | 빈 값 |
| Service type | `HTTP` |
| Service URL | `grafana:3000` |
| Additional application settings → Access → Protect with Access | 활성화 |
| Team name | 2단계에서 확인한 Zero Trust Team name |
| AUD | `Omagotchi Grafana` Application의 AUD |

- 최종 내부 목적지: `http://grafana:3000`
  - `127.0.0.1:13000` 입력 금지, cloudflared 안의 자기 주소로 해석
  - Host Header 등 추가 옵션은 기본값 유지
- `Protect with Access`: Tunnel에서도 Access 인증값 확인 후 Grafana로 전달하는 설정. [Cloudflare 원본 서버 보호](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/#access)
- 저장 후 해당 호스트의 DNS 연결 확인
  - 같은 이름의 기존 DNS Record와 충돌하면 대상부터 확인, 다른 업무 Record의 임의 삭제 금지
- Access 정책·원본 보호 설정을 모두 확인한 뒤 팀에 주소 공유

## 5. 브라우저에서 확인

- 새 시크릿 창에서 [Grafana](https://grafana.omagotchi.site) 접속
  - 먼저 Access 로그인 화면 표시
  - 허용된 이메일의 인증 완료 후 Grafana 로그인 화면 표시
  - Grafana 로그인: 기존 `omagotchi-admin`과 팀에서 관리하는 비밀번호
- `Dashboards` → `Omagotchi` → `Omagotchi HTTP 관측`
  - 대시보드 표시·새로고침·Tempo 조회 확인
  - 주소가 `http://`나 `127.0.0.1`로 바뀌지 않는지 확인
- 별도 시크릿 창의 미허용 이메일로 접근 차단 확인
  - `One-time PIN`은 미허용 이메일에 실제 코드 미발송, 안내 화면만으로 허용 판단 금지. [이메일 인증 동작](https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/one-time-pin/)
- 기존 `omagotchi.site`의 평소 화면 접속 유지 확인
- 운영 조회 방법: [팀 사용 가이드](https://github.com/nhnacademy-aiot3-omagotchi/docs/blob/main/40-operations/08-observability-usage.md)

## 6. 접속 실패 시 확인

- Access에서 차단: 허용 이메일·로그인 수단·Team name·AUD 확인
- `502`: Infra 배포 성공과 Grafana 실행 상태, 두 Container의 전용 Network 참여 확인
- 로그인 반복: HTTPS 주소·쿠키 차단·Access 세션 만료 확인
  - 인증을 끄거나 `Secure Cookie`를 해제하는 임시 우회 금지
- 도메인 경로의 비상 중단: Grafana Route 제거 후 Access 설정 유지
  - 공개 Route를 둔 채 Access부터 삭제하지 않는 순서
  - 화면 접속 중단과 데이터 수집·저장 중단은 별개, 볼륨 삭제 불필요
