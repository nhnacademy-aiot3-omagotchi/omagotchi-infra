"""제품 Rule 해석과 팀 확장의 안전 경계 검증. 외부 연결 없는 실행."""

import io
import os
import traceback
import unittest
from contextlib import redirect_stderr
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import requests
from elasticsearch import NotFoundError, TransportError
from elastalert.config import load_conf
from elastalert.elastalert import ElastAlerter
from elastalert.util import EAException

from bootstrap import AlertPreparationError, STATE_INDICES, setup_state_indices, verify_state_aliases
from runtime import CONFIG, configure_connection, main
from telegram_alert import OperationsTelegramAlerter


class TelegramAlertTest(unittest.TestCase):
    def test_product_loads_rule_and_sends_only_summary_fields(self):
        # Given: 실제 제품 Loader와 Token을 포함하지 않는 Rule 설정.
        args = SimpleNamespace(config=CONFIG, verbose=False, debug=False, es_debug=False, es_debug_trace=None)
        with patch.dict(os.environ, OPS_TELEGRAM_BOT_TOKEN="fixture-token", OPS_TELEGRAM_CHAT_ID="-100123"):
            conf = load_conf(args)
            rules = conf["rules_loader"].load(conf)
        self.assertEqual(len(rules), 1)
        alerter = rules[0]["alert"][0]
        match = {"service": {"name": "gateway-service"}, "error": {"code": "SYS_001", "type": "TimeoutError",
                 "stack_trace": "private-stack"}, "message": "요청 처리 실패\n확인 필요",
                 "http": {"request": {"id": "a" * 32, "body": "private-body"}},
                 "authorization": "private-token"}
        with patch("telegram_alert.requests.Session") as session_factory:
            session = session_factory.return_value.__enter__.return_value
            session.post.return_value.status_code = 200
            session.post.return_value.json.return_value = {"ok": True}
            # When: 대표 오류 전송.
            alerter.alert([match])
            # Then: 허용 필드·평문·Timeout·Redirect 경계, 인증 정보의 Writeback 제외.
            options = session.post.call_args.kwargs
            self.assertEqual(options["timeout"], (3, 5))
            self.assertFalse(options["allow_redirects"])
            self.assertFalse(session.trust_env)
            self.assertNotIn("parse_mode", options["json"])
            text = options["json"]["text"]
            self.assertIn("요약: 요청 처리 실패 확인 필요", text)
            self.assertIn('http.request.id : "' + "a" * 32 + '"', text)
            for secret in ("private-stack", "private-body", "private-token", "fixture-token"):
                self.assertNotIn(secret, text)
            self.assertNotIn("None", text)
            self.assertEqual(alerter.get_info(), {"type": "omagotchi-telegram"})

    def test_failure_does_not_leak_token_or_retry_inside_sender(self):
        # Given: Token URL이 포함된 Timeout·HTTP 오류 응답.
        with patch.dict(os.environ, OPS_TELEGRAM_BOT_TOKEN="fixture-token", OPS_TELEGRAM_CHAT_ID="-100123"):
            alerter = OperationsTelegramAlerter({})
        for failure in (requests.Timeout("https://api.telegram.org/botfixture-token/sendMessage"), 429, 302, 500):
            with self.subTest(failure=type(failure).__name__), patch("telegram_alert.requests.Session") as factory:
                session = factory.return_value.__enter__.return_value
                if isinstance(failure, Exception):
                    session.post.side_effect = failure
                else:
                    session.post.return_value.status_code = failure
                    session.post.return_value.text = "fixture-token"
                # When / Then: 한 번의 전송 실패를 제품에 위임, 원본 예외 연결 제외.
                try:
                    alerter.alert([{}])
                except EAException:
                    rendered = traceback.format_exc()
                else:
                    self.fail("실패 응답의 성공 처리")
                self.assertNotIn("fixture-token", rendered)
                session.post.assert_called_once()

    def test_missing_bot_settings_block_sender(self):
        # Given / When / Then: 미설정 상태의 전송기 생성 차단.
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(EAException):
            OperationsTelegramAlerter({})


class AlertRecoveryTest(unittest.TestCase):
    def test_unexpected_rule_error_does_not_pause_future_runs(self):
        # Given: 실제 제품 설정과 하나의 예약된 Rule. 외부 I/O만 대역 처리.
        args = SimpleNamespace(config=CONFIG, verbose=False, debug=False, es_debug=False, es_debug_trace=None)
        conf = load_conf(args)
        engine = object.__new__(ElastAlerter)
        rule = {"name": "fixture-rule"}
        engine.rules = [rule]
        engine.disabled_rules = []
        engine.disable_rules_on_error = conf["disable_rules_on_error"]
        engine.scheduler = MagicMock()
        engine.handle_error = MagicMock()
        engine.handle_notify_error = MagicMock()
        # When: 제품의 예상 밖 예외 처리 실행.
        with patch("elastalert.elastalert.elastalert_logger"):
            engine.handle_uncaught_exception(RuntimeError("fixture failure"), rule)
        # Then: 다음 조회의 예약 유지·실패 기록. 별도 복구 Loop 미사용.
        self.assertEqual(engine.rules, [rule])
        self.assertEqual(engine.disabled_rules, [])
        engine.scheduler.pause_job.assert_not_called()
        engine.handle_error.assert_called_once()

    def test_preparation_errors_show_safe_reason_without_external_details(self):
        # Given: 운영자 안내용 오류와 인증값이 포함된 라이브러리 예외.
        failures = (
            (AlertPreparationError("기존 알림 상태 ILM 발견"), "기존 알림 상태 ILM 발견"),
            (TransportError(401, "private-password"), "Elasticsearch 인증 실패"),
            (TransportError(403, "private-password"), "Elasticsearch 작업 권한 부족"),
            (ValueError("private-password"), "ValueError"),
        )
        environment = {"ELASTICSEARCH_URL": "http://fixture:9200", "ES_USERNAME": "fixture",
                       "ES_PASSWORD": "private-password", "OPS_TELEGRAM_BOT_TOKEN": "fixture-token",
                       "OPS_TELEGRAM_CHAT_ID": "-100123"}
        for failure, reason in failures:
            with self.subTest(reason=reason), patch.dict(os.environ, environment, clear=True), \
                    patch("sys.argv", ["runtime.py", "run"]), patch("runtime.elasticsearch_client") as factory, \
                    patch("runtime.os.execvp") as execute:
                factory.return_value.info.side_effect = failure
                output = io.StringIO()
                # When: 실제 실행 진입점에서 준비 실패.
                with redirect_stderr(output), self.assertRaises(SystemExit) as stopped:
                    main()
                # Then: 실패 종료·안전한 사유 출력·인증값 비노출·제품 실행 차단.
                self.assertEqual(stopped.exception.code, 1)
                self.assertIn(reason, output.getvalue())
                self.assertNotIn("private-password", output.getvalue())
                self.assertNotIn("fixture-token", output.getvalue())
                execute.assert_not_called()

    def test_invalid_url_does_not_expose_parser_input(self):
        # Given: Parser 오류에 포함될 수 있는 잘못된 Port 원문.
        with patch.dict(os.environ, ELASTICSEARCH_URL="http://fixture:private-token"):
            # When / Then: 원문 대신 설정 확인 안내만 전달.
            with self.assertRaises(AlertPreparationError) as failure:
                configure_connection()
            self.assertIn("URL·Port", str(failure.exception))
            self.assertNotIn("private-token", str(failure.exception))


class AlertBootstrapTest(unittest.TestCase):
    def test_existing_resource_or_failed_read_prevents_all_writes(self):
        # Given: 모든 조회 완료 전의 기존 자원·권한 오류 발견.
        for conflict in ("policy", "index", "template", "forbidden"):
            with self.subTest(conflict=conflict):
                client = MagicMock()
                client.ilm.get_lifecycle.side_effect = NotFoundError(404, "missing")
                client.indices.get.return_value = {}
                client.indices.get_index_template.side_effect = NotFoundError(404, "missing")
                if conflict == "policy":
                    client.ilm.get_lifecycle.side_effect = None
                elif conflict == "index":
                    client.indices.get.return_value = {"existing": {}}
                elif conflict == "template":
                    client.indices.get_index_template.side_effect = None
                else:
                    client.indices.get.side_effect = TransportError(403, "forbidden")
                # When / Then: 읽기 실패를 부재로 처리하지 않는 생성 경계.
                with self.assertRaises((ValueError, TransportError)):
                    setup_state_indices(client)
                client.ilm.put_lifecycle.assert_not_called()
                client.indices.put_index_template.assert_not_called()
                client.indices.create.assert_not_called()
                client.indices.delete.assert_not_called()

    def test_runtime_requires_write_alias_for_each_state_index(self):
        # Given: 조회는 가능하지만 쓰기 대상이 지정되지 않은 상태 Alias.
        client = MagicMock()
        alias = next(iter(STATE_INDICES))
        client.indices.get_alias.return_value = {"index": {"aliases": {alias: {}}}}
        # When / Then: 자동 Index 생성으로 우회하지 않는 실행 차단.
        with self.assertRaises(ValueError):
            verify_state_aliases(client)
        client.indices.create.assert_not_called()

    def test_connection_reuses_credentials_without_yaml_substitution(self):
        # Given: YAML·Shell에서 특별한 의미가 있는 비밀번호와 HTTPS 주소.
        environment = {"ELASTICSEARCH_URL": "https://es.example:9243/", "ES_USERNAME": "fixture",
                       "ES_PASSWORD": "quote' dollar$ colon: newline\n"}
        with patch.dict(os.environ, environment, clear=True):
            # When: URL을 제품 환경변수로 변환.
            connection = configure_connection()
            # Then: 인증 정보 보존·TLS·Port 반영.
            self.assertEqual(os.environ["ES_PASSWORD"], environment["ES_PASSWORD"])
            self.assertEqual(os.environ["ES_HOST"], "es.example")
            self.assertEqual(connection["es_port"], 9243)
            self.assertTrue(connection["use_ssl"])


if __name__ == "__main__":
    unittest.main()
