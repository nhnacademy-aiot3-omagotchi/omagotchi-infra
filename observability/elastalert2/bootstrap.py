"""알림 상태 저장소의 최초 생성. 기존 자원의 삭제·덮어쓰기 제외."""

from elasticsearch import NotFoundError
from elastalert.create_index import read_es_index_mappings

POLICY = "omagotchi-alert-state"
STATE_INDICES = {
    "elastalert-omagotchi-status": "elastalert",
    "elastalert-omagotchi-status_status": "elastalert_status",
    "elastalert-omagotchi-status_silence": "silence",
    "elastalert-omagotchi-status_error": "elastalert_error",
    "elastalert-omagotchi-status_past": "past_elastalert",
}


class AlertPreparationError(ValueError):
    """인증 정보 없이 운영자에게 안내 가능한 설정·상태 오류."""


def verify_state_aliases(client):
    """평상시 실행 전 다섯 상태 Alias의 쓰기 대상 확인."""
    for alias in STATE_INDICES:
        try:
            indices = client.indices.get_alias(name=alias)
        except NotFoundError:
            raise AlertPreparationError(f"알림 상태 Alias 누락: {alias}. 최초 생성·부분 생성 여부 확인 필요") from None
        writers = [entry for entry in indices.values()
                   if entry["aliases"][alias].get("is_write_index") is True]
        if len(writers) != 1:
            raise AlertPreparationError(f"알림 상태 Alias의 쓰기 대상 확인 필요: {alias}")


def setup_state_indices(client):
    """전체 자원 부재 확인 후 제품 Mapping·ILM 기반 상태 저장소 생성."""
    # 조회 실패를 부재로 간주하지 않는 경계. 부분 초기화 뒤에도 자동 재실행 금지.
    try:
        client.ilm.get_lifecycle(policy=POLICY)
    except NotFoundError:
        pass
    else:
        raise AlertPreparationError(f"기존 알림 상태 ILM 발견: {POLICY}. 초기화 재실행 금지")
    for alias in STATE_INDICES:
        existing = client.indices.get(index=f"{alias},{alias}-*", ignore_unavailable=True, allow_no_indices=True)
        if existing:
            raise AlertPreparationError(f"기존 알림 상태 Index·Alias 발견: {alias}. 초기화 재실행 금지")
        try:
            client.indices.get_index_template(name=alias)
        except NotFoundError:
            pass
        else:
            raise AlertPreparationError(f"기존 알림 상태 Template 발견: {alias}. 초기화 재실행 금지")

    mappings = read_es_index_mappings()
    client.ilm.put_lifecycle(policy=POLICY, body={"policy": {"phases": {
        "hot": {"actions": {"rollover": {"max_age": "1d", "max_primary_shard_size": "100mb"}}},
        "delete": {"min_age": "3d", "actions": {"delete": {}}},
    }}})
    for alias, mapping_name in STATE_INDICES.items():
        # Alias를 통해 조회·쓰기를 유지하고, 오래된 상태 Index는 ILM에서 정리.
        template = {
            "settings": {"index.number_of_shards": 1,
                         "index.lifecycle.name": POLICY,
                         "index.lifecycle.rollover_alias": alias},
            "mappings": mappings[mapping_name],
        }
        client.indices.put_index_template(name=alias, body={
            "index_patterns": [f"{alias}-*"],
            "priority": 250,
            "_meta": {"owner": "omagotchi"},
            "template": template,
        })
        # 공용 Template의 높은 우선순위로 후속 Rollover의 보존 정책이 빠지는 상황 차단.
        simulated = client.transport.perform_request("POST", f"/_index_template/_simulate_index/{alias}-000001")
        lifecycle = simulated["template"]["settings"]["index"].get("lifecycle", {})
        if lifecycle.get("name") != POLICY or lifecycle.get("rollover_alias") != alias:
            raise AlertPreparationError(f"공용 Template과 알림 상태 보존 정책의 충돌: {alias}. 부분 생성 상태 확인 필요")
        client.indices.create(index=f"{alias}-000001", body={
            **template,
            "aliases": {alias: {"is_write_index": True}},
        })
