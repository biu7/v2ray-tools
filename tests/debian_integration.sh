#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /etc/debian_version ]]; then
  echo "This integration test is intended to run inside Debian." >&2
  exit 1
fi

export TERM=dumb

apt-get update
apt-get install -y --no-install-recommends bash ca-certificates curl jq openssl systemd unzip

touch /.dockerenv
installer="$(mktemp)"
curl -fsSL "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "${installer}"
bash "${installer}" install --without-geodata --without-logfiles --no-update-service
rm -f "${installer}"

XRAY_TOOLS_TESTING=1 source ./install-xray.sh

uuid="$(generate_uuid)"
read -r private_key public_key < <(generate_reality_keypair)
short_id="$(generate_short_id)"
ss_password="$(generate_ss2022_password)"

config="$(default_config_json)"
vless="$(vless_reality_inbound_json "443" "${uuid}" "www.microsoft.com" "443" "${private_key}" "${public_key}" "${short_id}" "docker-vless")"
ss="$(ss2022_inbound_json "8443" "${ss_password}" "docker-ss")"
config="$(append_inbound_json "${config}" "${vless}")"
config="$(append_inbound_json "${config}" "${ss}")"

validation_config="$(make_validation_temp_file /tmp)"
jq . <<<"${config}" >"${validation_config}"
/usr/local/bin/xray run -test -config "${validation_config}"
rm -rf "$(dirname "${validation_config}")"

bash -n install-xray.sh tests/install_xray_test.sh
bash tests/install_xray_test.sh

printf 'ok - debian integration passed\n'
