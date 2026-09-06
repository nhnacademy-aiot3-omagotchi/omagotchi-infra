"""공통 Elasticsearch URL의 제품 환경변수 변환·최초 생성과 상시 실행의 분리."""

import os
import sys
from urllib.parse import urlsplit

from elasticsearch import TransportError
from elastalert.util import elasticsearch_client

from bootstrap import AlertPreparationError, setup_state_indices, verify_state_aliases

CONFIG = "/opt/elastalert/omagotchi/config.yaml"


def configure_connection():
    """기존 prod.env의 접속 정보를 파일·명령 인자 노출 없이 재사용."""
    try:
        url = urlsplit(os.environ.get("ELASTICSEARCH_URL", ""))
        port = url.port or (443 if url.scheme == "https" else 80)
    except ValueError:
        # URL Parser의 예외에 포함될 수 있는 원본 접속값 제외.
        raise AlertPreparationError("Elasticsearch URL·Port 형식 확인 필요") from None
    if (url.scheme not in ("http", "https") or not url.hostname or url.username or url.password
            or url.query or url.fragment or url.path not in ("", "/")):
        raise AlertPreparationError("Elasticsearch URL 형식 확인 필요")
    if not os.environ.get("ES_USERNAME") or not os.environ.get("ES_PASSWORD"):
        raise AlertPreparationError("Elasticsearch 사용자명·비밀번호 설정 필요")
    os.environ.update(ES_HOST=url.hostname, ES_PORT=str(port),
                      ES_USE_SSL=str(url.scheme == "https"))
    return {"es_host": url.hostname, "es_port": int(os.environ["ES_PORT"]),
            "use_ssl": url.scheme == "https", "es_conn_timeout": 10, "verify_certs": True}


def main():
    stage = "접속 설정 확인"
    try:
        connection = configure_connection()
        mode = sys.argv[1] if len(sys.argv) == 2 else ""
        if mode not in ("run", "setup"):
            raise AlertPreparationError("실행 모드 run 또는 setup 지정 필요")
        # 상태 초기화에는 Telegram 인증 정보 불필요. 상시 실행 전에는 필수.
        if mode == "run" and (not os.environ.get("OPS_TELEGRAM_BOT_TOKEN")
                              or not os.environ.get("OPS_TELEGRAM_CHAT_ID")):
            raise AlertPreparationError("운영 알림 Bot Token·Chat ID 설정 필요")
        stage = "Elasticsearch 연결·버전 확인"
        client = elasticsearch_client(connection)
        if not str(client.info()["version"]["number"]).startswith("8."):
            raise AlertPreparationError("검증한 Elasticsearch 8.x 범위 밖의 버전")
        if mode == "setup":
            stage = "상태 저장소 최초 생성 — 실패 시 부분 생성 여부 확인"
            setup_state_indices(client)
            print("알림 상태 저장소 최초 생성 완료. Telegram 전송 없음.")
            return
        stage = "상태 Alias의 쓰기 대상 확인"
        verify_state_aliases(client)
    except AlertPreparationError as error:
        print(f"알림 실행 준비 실패: {error}", file=sys.stderr)
        sys.exit(1)
    except TransportError as error:
        # 고정 안내만 출력. HTTP 응답·인증 정보·접속 URL의 원문 제외.
        reason = {401: "Elasticsearch 인증 실패", 403: "Elasticsearch 작업 권한 부족",
                  404: "Elasticsearch 대상 자원 없음"}.get(error.status_code, "Elasticsearch 통신·요청 실패")
        print(f"알림 실행 준비 실패: {reason} ({stage}).", file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # 접속 예외의 URL·인증·응답 원문 출력 제외. 실패 종류만 안내.
        print(f"알림 실행 준비 실패: {stage} ({type(error).__name__}). 원인 확인 필요.", file=sys.stderr)
        sys.exit(1)
    os.execvp("elastalert", ["elastalert", "--config", CONFIG, "--pin_rules"])


if __name__ == "__main__":
    main()
