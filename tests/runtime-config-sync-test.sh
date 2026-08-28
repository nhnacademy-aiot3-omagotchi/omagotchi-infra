#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP_DIR}"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  local message="$3"

  grep -Fq -- "${pattern}" "${file}" || fail "${message}"
}

assert_not_contains() {
  local pattern="$1"
  local file="$2"
  local message="$3"

  if grep -Fq -- "${pattern}" "${file}"; then
    fail "${message}"
  fi
}

file_mode() {
  local file="$1"

  stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}"
}

fixture_root="${TEST_TMP_DIR}/omagotchi"
fixture_dir="${fixture_root}/infra"
secrets_dir="${fixture_root}/secrets"
fake_bin="${TEST_TMP_DIR}/bin"
events_file="${TEST_TMP_DIR}/events"
output_file="${TEST_TMP_DIR}/output"
sha="1111111111111111111111111111111111111111"

mkdir -p \
  "${fixture_dir}/.git" \
  "${fixture_dir}/scripts" \
  "${secrets_dir}" \
  "${fake_bin}"

printf 'SMOKE_BASE_URL=https://example.invalid\n' >"${fixture_dir}/deploy.env"
printf 'CURRENT_SECRET=old-runtime-value\n' >"${secrets_dir}/prod.env"

cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  branch) printf 'main\n' ;;
  status)
    if [[ "${SYNC_TEST_GIT_DIRTY:-false}" == "true" ]]; then
      printf ' M compose.yaml\n'
    fi
    ;;
  rev-parse) printf '0000000000000000000000000000000000000000\n' ;;
  fetch | cat-file | merge-base | merge) ;;
  *) exit 1 ;;
esac
EOF

cat >"${fake_bin}/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"${fixture_dir}/scripts/compose.sh" <<'EOF'
#!/usr/bin/env bash
printf 'compose:%s\n' "$*" >>"${SYNC_TEST_EVENTS}"
if [[ "${SYNC_TEST_COMPOSE_FAIL:-false}" == "true" ]]; then
  echo 'compose parser error: NEW_SECRET=new-runtime-value' >&2
  exit 1
fi
grep -Fq 'NEW_SECRET=new-runtime-value' "${SECRET_ENV_FILE}"
EOF

chmod +x \
  "${fake_bin}/flock" \
  "${fake_bin}/git" \
  "${fixture_dir}/scripts/compose.sh"

candidate="${secrets_dir}/.incoming-prod.env.success"
printf 'NEW_SECRET=new-runtime-value\n' >"${candidate}"

if ! SYNC_TEST_EVENTS="${events_file}" PATH="${fake_bin}:${PATH}" \
  bash "${INFRA_DIR}/scripts/sync-runtime-config.sh" \
    "${fixture_dir}" "${sha}" "${candidate}" \
    >"${output_file}" 2>&1; then
  sed 's/=.*/=<redacted>/' "${output_file}" >&2
  fail "정상 Runtime 설정 동기화가 실패했습니다."
fi

assert_contains 'NEW_SECRET=new-runtime-value' "${secrets_dir}/prod.env" \
  "검증된 후보 Runtime 설정이 prod.env로 확정되지 않았습니다."
assert_contains 'CURRENT_SECRET=old-runtime-value' "${secrets_dir}/prod.env.previous" \
  "기존 Runtime 설정의 직전 복구본이 보존되지 않았습니다."
[[ ! -e "${candidate}" ]] || fail "동기화 성공 이후 후보 Runtime 설정이 남았습니다."
[[ "$(file_mode "${secrets_dir}/prod.env")" == "600" ]] || \
  fail "확정된 prod.env 권한이 600이 아닙니다."
[[ "$(file_mode "${secrets_dir}/prod.env.previous")" == "600" ]] || \
  fail "prod.env.previous 권한이 600이 아닙니다."
assert_contains 'compose:config --quiet' "${events_file}" \
  "Runtime 설정 교체 전 Compose 검증이 실행되지 않았습니다."
[[ "$(wc -l <"${events_file}" | tr -d '[:space:]')" == "1" ]] || \
  fail "Runtime 설정 동기화 중 Compose 검증 외의 명령이 실행되었습니다."
assert_not_contains 'up' "${events_file}" \
  "Runtime 설정 동기화 중 Container 기동이 실행되었습니다."
assert_not_contains 'pull' "${events_file}" \
  "Runtime 설정 동기화 중 Image Pull이 실행되었습니다."
assert_not_contains 'new-runtime-value' "${output_file}" \
  "새 Runtime Secret이 동기화 Log에 노출되었습니다."
assert_not_contains 'old-runtime-value' "${output_file}" \
  "기존 Runtime Secret이 동기화 Log에 노출되었습니다."

candidate="${secrets_dir}/.incoming-prod.env.unchanged"
cp "${secrets_dir}/prod.env" "${candidate}"

if ! SYNC_TEST_EVENTS="${events_file}" PATH="${fake_bin}:${PATH}" \
  bash "${INFRA_DIR}/scripts/sync-runtime-config.sh" \
    "${fixture_dir}" "${sha}" "${candidate}" \
    >"${output_file}" 2>&1; then
  fail "동일한 Runtime 설정의 반복 동기화가 실패했습니다."
fi

assert_contains 'CURRENT_SECRET=old-runtime-value' "${secrets_dir}/prod.env.previous" \
  "동일한 Runtime 설정이 기존 복구본을 덮어썼습니다."
[[ ! -e "${candidate}" ]] || fail "변경 없는 Runtime 설정 후보가 남았습니다."
assert_contains 'Runtime 설정 변경 없음' "${output_file}" \
  "동일한 Runtime 설정의 교체 생략 상태가 명시되지 않았습니다."

printf 'CURRENT_SECRET=stable-runtime-value\n' >"${secrets_dir}/prod.env"
candidate="${secrets_dir}/.incoming-prod.env.invalid"
printf 'NEW_SECRET=new-runtime-value\n' >"${candidate}"

if SYNC_TEST_EVENTS="${events_file}" SYNC_TEST_COMPOSE_FAIL=true PATH="${fake_bin}:${PATH}" \
  bash "${INFRA_DIR}/scripts/sync-runtime-config.sh" \
    "${fixture_dir}" "${sha}" "${candidate}" \
    >"${output_file}" 2>&1; then
  fail "Compose 검증에 실패한 Runtime 설정이 확정되었습니다."
fi

assert_contains 'CURRENT_SECRET=stable-runtime-value' "${secrets_dir}/prod.env" \
  "Compose 검증 실패 이후 기존 prod.env가 변경되었습니다."
assert_contains 'CURRENT_SECRET=old-runtime-value' "${secrets_dir}/prod.env.previous" \
  "Compose 검증 실패 이후 직전 Runtime 설정 복구본이 변경되었습니다."
[[ ! -e "${candidate}" ]] || fail "Compose 검증 실패 이후 후보 Runtime 설정이 남았습니다."
assert_contains 'Secret 보호를 위해 상세 출력은 생략합니다' "${output_file}" \
  "Compose 검증 실패 시 Secret 보호 안내가 출력되지 않았습니다."
assert_not_contains 'new-runtime-value' "${output_file}" \
  "Compose 검증 실패의 상세 출력에서 Runtime Secret이 노출되었습니다."
if find "${secrets_dir}" -maxdepth 1 -name '.runtime-config-validation.*' | grep -q .; then
  fail "Compose 검증 실패 이후 상세 출력 임시 파일이 남았습니다."
fi

candidate="${secrets_dir}/.incoming-prod.env.duplicate"
printf 'DUPLICATE=value-one\nDUPLICATE=value-two\n' >"${candidate}"

if SYNC_TEST_EVENTS="${events_file}" PATH="${fake_bin}:${PATH}" \
  bash "${INFRA_DIR}/scripts/sync-runtime-config.sh" \
    "${fixture_dir}" "${sha}" "${candidate}" \
    >"${output_file}" 2>&1; then
  fail "중복 Key가 포함된 Runtime 설정이 허용되었습니다."
fi
assert_contains '후보 prod.env에 중복 Key가 있습니다' "${output_file}" \
  "Runtime 설정 중복 Key의 실패 원인이 출력되지 않았습니다."
[[ ! -e "${candidate}" ]] || fail "중복 Key 검증 실패 이후 후보 Runtime 설정이 남았습니다."

candidate="${secrets_dir}/.incoming-prod.env.dirty"
printf 'NEW_SECRET=new-runtime-value\n' >"${candidate}"

if SYNC_TEST_EVENTS="${events_file}" SYNC_TEST_GIT_DIRTY=true PATH="${fake_bin}:${PATH}" \
  bash "${INFRA_DIR}/scripts/sync-runtime-config.sh" \
    "${fixture_dir}" "${sha}" "${candidate}" \
    >"${output_file}" 2>&1; then
  fail "서버 Infra 추적 파일 변경이 있는 상태에서 설정 동기화가 허용되었습니다."
fi
assert_contains '추적 파일 변경이 있어 설정 동기화를 중단합니다' "${output_file}" \
  "서버 Infra 변경 상태의 동기화 실패 원인이 출력되지 않았습니다."
[[ ! -e "${candidate}" ]] || fail "Git 상태 검증 실패 이후 후보 Runtime 설정이 남았습니다."

echo "Runtime configuration sync tests passed"
