"""운영 오류 요약의 Telegram 전송. 조회·억제·재시도는 ElastAlert2의 책임."""

import json
import os
import re
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode

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
        occurred_at = None
        time_range = None
        try:
            # 제품이 변환한 datetime과 Elasticsearch의 ISO 시각 모두 허용.
            timestamp = lookup_es_key(match, "@timestamp")
            parsed = timestamp if isinstance(timestamp, datetime) else datetime.fromisoformat(timestamp)
            if parsed.tzinfo is not None:
                occurred_at = parsed.astimezone(timezone(timedelta(hours=9)))
                time_range = (parsed - timedelta(minutes=5), parsed + timedelta(minutes=5))
        except (TypeError, ValueError, OverflowError):
            # 잘못된 시각 하나로 오류 알림 전체가 중단되지 않도록 원문 표시 유지.
            occurred_at = None

        lines = ["[오류] Omagotchi"]
        fields = (
            ("서비스", "service.name"),
            ("오류 코드", "error.code"),
            ("오류 종류", "error.type"),
            ("시각", "@timestamp"),
            ("HTTP 상태", "http.response.status_code"),
            ("요약", "message"),
            ("경로", "omagotchi.http.route"),
            ("Gateway Route", "gateway.route.id"),
            ("Request ID", "http.request.id"),
            ("Trace ID", "trace.id"),
        )
        for label, field in fields:
            value = lookup_es_key(match, field)
            if field == "@timestamp" and occurred_at is not None:
                label, value = "시각 (한국)", occurred_at.strftime("%Y-%m-%d %H:%M:%S KST")
            if value is not None and not isinstance(value, (dict, list)):
                # 계약상 안전한 필드만 사용. 개행·장문에 의한 메시지 형식 훼손 방지.
                lines.append(f"{label}: {' '.join(str(value).split())[:200]}")

        request_id = lookup_es_key(match, "http.request.id")
        trace_id = lookup_es_key(match, "trace.id")
        # 검색식과 URL에는 현재 식별자 계약을 만족하는 값만 포함.
        if not isinstance(request_id, str) or not re.fullmatch(r"[0-9a-f]{32}", request_id):
            request_id = None
        if not isinstance(trace_id, str) or not re.fullmatch(r"[0-9a-f]{32}", trace_id):
            trace_id = None
        if request_id:
            lines.append(f'검색: http.request.id : "{request_id}"')
        if time_range is None:
            lines.append("조회 시각 확인 필요: 화면에서 발생 시간 범위 직접 선택")

        # 명시적 Timeout·TLS 검증·Redirect 차단. API 원문·예외 URL의 로그 출력 제외.
        payload = {
            "chat_id": self.chat_id,
            "text": "\n".join(lines),
            "disable_web_page_preview": True,
            "reply_markup": {"inline_keyboard": [build_investigation_buttons(request_id, trace_id, time_range)]},
        }
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


def build_investigation_buttons(request_id, trace_id, time_range):
    """검증된 식별자와 발생 시각을 사용하는 Kibana·Grafana 조회 버튼 구성."""
    # Kibana 8.19.3의 Locator 사용. 임시 Data view로 팀 로그만 조회, 저장 객체 생성 없음.
    discover = {
        "dataViewSpec": {"title": "logs-omagotchi-prod", "timeFieldName": "@timestamp"},
        "columns": ["service.name", "http.response.status_code", "event.duration", "error.type", "message"],
        "sort": [["@timestamp", "asc"]],
        "refreshInterval": {"pause": True, "value": 0},
    }
    if request_id or trace_id:
        field, value = ("http.request.id", request_id) if request_id else ("trace.id", trace_id)
        discover["query"] = {"language": "kuery", "query": f'{field} : "{value}"'}
    if time_range:
        discover["timeRange"] = {
            "from": time_range[0].astimezone(timezone.utc).isoformat(),
            "to": time_range[1].astimezone(timezone.utc).isoformat(),
        }
    kibana_query = urlencode({
        "l": "DISCOVER_APP_LOCATOR", "v": "8.19.3",
        "p": json.dumps(discover, separators=(",", ":")),
    })
    buttons = [{
        "text": "요청 로그 보기" if request_id else "로그 보기",
        "url": "http://s4.java21.net:5601/s/aiot3-team5-omagotchi/app/r?" + kibana_query,
    }]

    if trace_id:
        # Grafana Explore의 공개 URL 형식 사용. 긴 주소의 본문 노출·단축 URL 저장 제외.
        pane = {
            "datasource": "omagotchi-tempo",
            "queries": [{
                "refId": "A", "datasource": {"uid": "omagotchi-tempo", "type": "tempo"},
                "queryType": "traceql", "query": trace_id,
            }],
            "range": {"from": "now-15m", "to": "now"},
        }
        if time_range:
            pane["range"] = {
                "from": str(int(time_range[0].timestamp() * 1000)),
                "to": str(int(time_range[1].timestamp() * 1000)),
            }
        grafana_query = urlencode({
            "schemaVersion": 1, "orgId": 1,
            "panes": json.dumps({"A": pane}, separators=(",", ":")),
        })
        buttons.append({"text": "Trace 보기", "url": "https://grafana.omagotchi.site/explore?" + grafana_query})
    return buttons
