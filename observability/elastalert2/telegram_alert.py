"""운영 오류 요약의 Telegram 전송. 조회·억제·재시도는 ElastAlert2의 책임."""

import os
import re

import requests
from elastalert.alerts import Alerter
from elastalert.util import EAException, lookup_es_key


class OperationsTelegramAlerter(Alerter):
    """허용 필드의 평문 전송·제한 시간·실패 로그의 인증 정보 보호."""

    def __init__(self, rule):
        super().__init__(rule)
        self.token = os.environ.get("OPS_TELEGRAM_BOT_TOKEN", "")
        self.chat_id = os.environ.get("OPS_TELEGRAM_CHAT_ID", "")
        if not self.token or not self.chat_id:
            raise EAException("운영 알림 Bot Token·Chat ID 설정 필요")

    def alert(self, matches):
        # 최초 대표 오류 한 건. 묶음 요약·억제 건수로 해석 금지.
        match = matches[0]
        lines = ["[오류] Omagotchi"]
        fields = (
            ("서비스", "service.name"),
            ("오류 코드", "error.code"),
            ("오류 종류", "error.type"),
            ("시각", "@timestamp"),
            ("요약", "message"),
            ("경로", "omagotchi.http.route"),
            ("Gateway Route", "gateway.route.id"),
            ("Request ID", "http.request.id"),
            ("Trace ID", "trace.id"),
        )
        for label, field in fields:
            value = lookup_es_key(match, field)
            if value is not None and not isinstance(value, (dict, list)):
                # 계약상 안전한 필드만 사용. 개행·장문에 의한 메시지 형식 훼손 방지.
                lines.append(f"{label}: {' '.join(str(value).split())[:200]}")

        request_id = lookup_es_key(match, "http.request.id")
        if isinstance(request_id, str) and re.fullmatch(r"[0-9a-f]{32}", request_id):
            lines.append(f'검색: http.request.id : "{request_id}"')
        lines.append("Kibana Space: http://s4.java21.net:5601/s/aiot3-team5-omagotchi/")

        # 명시적 Timeout·TLS 검증·Redirect 차단. API 원문·예외 URL의 로그 출력 제외.
        payload = {"chat_id": self.chat_id, "text": "\n".join(lines), "disable_web_page_preview": True}
        with requests.Session() as session:
            session.trust_env = False
            try:
                response = session.post(
                    f"https://api.telegram.org/bot{self.token}/sendMessage",
                    json=payload,
                    timeout=(3, 5),
                    allow_redirects=False,
                )
                if response.status_code != 200:
                    raise EAException(f"Telegram 전송 실패 (HTTP {response.status_code})")
                result = response.json()
                if not isinstance(result, dict) or result.get("ok") is not True:
                    raise EAException("Telegram 전송 거절")
            except (requests.RequestException, ValueError):
                # 예외 연결까지 제거해 Bot Token 포함 URL의 Traceback 유출 방지.
                raise EAException("Telegram 통신 실패 또는 응답 형식 오류") from None

    def get_info(self):
        # Writeback의 알림 설명에 Token·Chat ID 미포함.
        return {"type": "omagotchi-telegram"}
