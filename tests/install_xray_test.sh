#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/install-xray.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    fail "${message}: expected '${expected}', got '${actual}'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail "${message}: expected '${haystack}' to contain '${needle}'"
  fi
}

XRAY_TOOLS_TESTING=1 source "${SCRIPT}"

test_default_config_has_outbounds() {
  local config
  config="$(default_config_json)"

  assert_eq "direct" "$(jq -r '.outbounds[0].tag' <<<"${config}")" "default direct outbound tag"
  assert_eq "freedom" "$(jq -r '.outbounds[0].protocol' <<<"${config}")" "default direct outbound protocol"
  assert_eq "block" "$(jq -r '.outbounds[1].tag' <<<"${config}")" "default block outbound tag"
  assert_eq "blackhole" "$(jq -r '.outbounds[1].protocol' <<<"${config}")" "default block outbound protocol"
}

test_vless_reality_inbound() {
  local inbound
  inbound="$(vless_reality_inbound_json "443" "11111111-1111-4111-8111-111111111111" "example.com" "443" "private-key" "public-key" "a1b2c3d4e5f6a7b8" "demo")"

  assert_eq "vless-reality-443" "$(jq -r '.tag' <<<"${inbound}")" "vless tag"
  assert_eq "443" "$(jq -r '.port' <<<"${inbound}")" "vless port"
  assert_eq "vless" "$(jq -r '.protocol' <<<"${inbound}")" "vless protocol"
  assert_eq "xtls-rprx-vision" "$(jq -r '.settings.clients[0].flow' <<<"${inbound}")" "vless vision flow"
  assert_eq "tcp" "$(jq -r '.streamSettings.network' <<<"${inbound}")" "vless tcp network"
  assert_eq "reality" "$(jq -r '.streamSettings.security' <<<"${inbound}")" "vless reality security"
  assert_eq "example.com:443" "$(jq -r '.streamSettings.realitySettings.target' <<<"${inbound}")" "vless reality target"
  assert_eq "private-key" "$(jq -r '.streamSettings.realitySettings.privateKey' <<<"${inbound}")" "vless private key"
  assert_eq "public-key" "$(jq -r '.streamSettings.realitySettings.publicKey' <<<"${inbound}")" "vless public key"
  assert_eq "a1b2c3d4e5f6a7b8" "$(jq -r '.streamSettings.realitySettings.shortIds[0]' <<<"${inbound}")" "vless short id"
}

test_ss2022_inbound() {
  local inbound
  inbound="$(ss2022_inbound_json "443" "secret-password" "demo")"

  assert_eq "shadowsocks-2022-443" "$(jq -r '.tag' <<<"${inbound}")" "ss tag"
  assert_eq "443" "$(jq -r '.port' <<<"${inbound}")" "ss port"
  assert_eq "shadowsocks" "$(jq -r '.protocol' <<<"${inbound}")" "ss protocol"
  assert_eq "2022-blake3-aes-256-gcm" "$(jq -r '.settings.method' <<<"${inbound}")" "ss method"
  assert_eq "secret-password" "$(jq -r '.settings.password' <<<"${inbound}")" "ss password"
  assert_eq "demo" "$(jq -r '.settings.email' <<<"${inbound}")" "ss email"
  assert_eq "true" "$(jq -r '.settings.network == "tcp,udp"' <<<"${inbound}")" "ss network"
}

test_append_inbound_preserves_existing() {
  local config vless ss merged
  config="$(default_config_json)"
  vless="$(vless_reality_inbound_json "443" "11111111-1111-4111-8111-111111111111" "example.com" "443" "private-key" "public-key" "a1b2c3d4e5f6a7b8" "demo")"
  ss="$(ss2022_inbound_json "8443" "secret-password" "ss-demo")"
  merged="$(append_inbound_json "${config}" "${vless}")"
  merged="$(append_inbound_json "${merged}" "${ss}")"

  assert_eq "2" "$(jq -r '.inbounds | length' <<<"${merged}")" "two inbounds appended"
  assert_eq "vless-reality-443" "$(jq -r '.inbounds[0].tag' <<<"${merged}")" "first inbound preserved"
  assert_eq "shadowsocks-2022-8443" "$(jq -r '.inbounds[1].tag' <<<"${merged}")" "second inbound appended"
  assert_eq "direct" "$(jq -r '.outbounds[0].tag' <<<"${merged}")" "outbounds preserved"
}

test_read_config_or_default_preserves_existing_file() {
  local tmpdir old_config_path loaded
  tmpdir="$(mktemp -d)"
  old_config_path="${XRAY_CONFIG_PATH}"
  XRAY_CONFIG_PATH="${tmpdir}/config.json"

  cat >"${XRAY_CONFIG_PATH}" <<'JSON'
{
  "inbounds": [
    {
      "tag": "existing",
      "port": 10000,
      "protocol": "http"
    }
  ]
}
JSON

  loaded="$(read_config_or_default)"
  XRAY_CONFIG_PATH="${old_config_path}"
  rm -rf "${tmpdir}"

  assert_eq "existing" "$(jq -r '.inbounds[0].tag' <<<"${loaded}")" "existing inbound loaded"
  assert_eq "direct" "$(jq -r '.outbounds[0].tag' <<<"${loaded}")" "default outbounds added"
  assert_eq "warning" "$(jq -r '.log.loglevel' <<<"${loaded}")" "default log added"
}

test_xray_config_validation_uses_current_cli() {
  local tmpdir old_xray_bin args_file
  tmpdir="$(mktemp -d)"
  old_xray_bin="${XRAY_BIN}"
  args_file="${tmpdir}/args"
  XRAY_BIN="${tmpdir}/xray"
  XRAY_FAKE_ARGS_FILE="${args_file}"
  export XRAY_FAKE_ARGS_FILE

  cat >"${XRAY_BIN}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${XRAY_FAKE_ARGS_FILE}"
if [[ "$1" == "run" && "$2" == "-test" && "$3" == "-config" ]]; then
  exit 0
fi
exit 2
SH
  chmod +x "${XRAY_BIN}"

  test_xray_config "${tmpdir}/config.json"

  XRAY_BIN="${old_xray_bin}"
  unset XRAY_FAKE_ARGS_FILE
  assert_eq "run -test -config ${tmpdir}/config.json" "$(cat "${args_file}")" "xray validation command"
  rm -rf "${tmpdir}"
}

test_config_permissions_are_service_readable() {
  local tmpdir config_file mode
  tmpdir="$(mktemp -d)"
  config_file="${tmpdir}/config.json"
  printf '{}\n' >"${config_file}"

  set_config_permissions "${config_file}"
  mode="$(stat -c '%a' "${config_file}" 2>/dev/null || stat -f '%Lp' "${config_file}")"

  assert_eq "644" "${mode}" "config file mode"
  rm -rf "${tmpdir}"
}

test_warn_writes_to_stderr() {
  local tmpdir stdout stderr
  tmpdir="$(mktemp -d)"

  stdout="$(warn "warning text" 2>"${tmpdir}/stderr")"
  stderr="$(cat "${tmpdir}/stderr")"

  assert_eq "" "${stdout}" "warn stdout"
  assert_contains "${stderr}" "warning text" "warn stderr"
  rm -rf "${tmpdir}"
}

test_share_links() {
  local vless_link ss_link
  vless_link="$(vless_reality_link "203.0.113.10" "443" "11111111-1111-4111-8111-111111111111" "example.com" "public-key" "a1b2c3d4e5f6a7b8" "demo name")"
  ss_link="$(ss2022_link "203.0.113.10" "8443" "2022-blake3-aes-256-gcm" "secret-password" "ss demo")"

  assert_contains "${vless_link}" "vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443?" "vless scheme"
  assert_contains "${vless_link}" "security=reality" "vless security"
  assert_contains "${vless_link}" "type=tcp" "vless tcp"
  assert_contains "${vless_link}" "sni=example.com" "vless sni"
  assert_contains "${vless_link}" "pbk=public-key" "vless public key"
  assert_contains "${vless_link}" "sid=a1b2c3d4e5f6a7b8" "vless short id"
  assert_contains "${vless_link}" "flow=xtls-rprx-vision" "vless flow"
  assert_contains "${vless_link}" "#demo%20name" "vless encoded remark"

  assert_contains "${ss_link}" "ss://" "ss scheme"
  assert_contains "${ss_link}" "@203.0.113.10:8443#ss%20demo" "ss server and encoded remark"
}

main() {
  test_default_config_has_outbounds
  test_vless_reality_inbound
  test_ss2022_inbound
  test_append_inbound_preserves_existing
  test_read_config_or_default_preserves_existing_file
  test_xray_config_validation_uses_current_cli
  test_config_permissions_are_service_readable
  test_warn_writes_to_stderr
  test_share_links
  printf 'ok - install-xray tests passed\n'
}

main "$@"
