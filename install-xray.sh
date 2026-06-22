#!/usr/bin/env bash
set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG_PATH="${XRAY_CONFIG_PATH:-/usr/local/etc/xray/config.json}"
XRAY_SERVICE="${XRAY_SERVICE:-xray.service}"
SS2022_METHOD="${SS2022_METHOD:-2022-blake3-aes-256-gcm}"
DEFAULT_PORT="${DEFAULT_PORT:-443}"
DEFAULT_REALITY_DOMAIN="${DEFAULT_REALITY_DOMAIN:-www.microsoft.com}"

info() {
  printf '\033[1;34m%s\033[0m\n' "$*"
}

success() {
  printf '\033[1;32m%s\033[0m\n' "$*"
}

warn() {
  printf '\033[1;33m%s\033[0m\n' "$*" >&2
}

die() {
  printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    die "请使用 root 用户运行，或使用 sudo 执行此脚本"
  fi
}

require_command() {
  command_exists "$1" || die "缺少依赖命令: $1"
}

require_jq() {
  require_command jq
}

urlencode() {
  local string="$1"
  local strlen=${#string}
  local encoded=""
  local pos c out

  for ((pos = 0; pos < strlen; pos++)); do
    c="${string:${pos}:1}"
    case "${c}" in
      [a-zA-Z0-9.~_-])
        out="${c}"
        ;;
      *)
        printf -v out '%%%02X' "'${c}"
        ;;
    esac
    encoded="${encoded}${out}"
  done

  printf '%s' "${encoded}"
}

base64_urlsafe() {
  base64 | tr -d '\n=' | tr '+/' '-_'
}

default_config_json() {
  jq -n '{
    log: {
      loglevel: "warning"
    },
    inbounds: [],
    outbounds: [
      {
        tag: "direct",
        protocol: "freedom"
      },
      {
        tag: "block",
        protocol: "blackhole"
      }
    ]
  }'
}

ensure_base_sections_json() {
  local config="$1"

  jq '
    .inbounds = (.inbounds // []) |
    .outbounds = (
      .outbounds //
      [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
      ]
    ) |
    .log = (.log // {"loglevel": "warning"})
  ' <<<"${config}"
}

vless_reality_inbound_json() {
  local port="$1"
  local uuid="$2"
  local reality_domain="$3"
  local reality_target_port="$4"
  local private_key="$5"
  local public_key="$6"
  local short_id="$7"
  local remark="$8"

  jq -n \
    --arg port "${port}" \
    --arg uuid "${uuid}" \
    --arg reality_domain "${reality_domain}" \
    --arg reality_target_port "${reality_target_port}" \
    --arg private_key "${private_key}" \
    --arg public_key "${public_key}" \
    --arg short_id "${short_id}" \
    --arg remark "${remark}" \
    '{
      tag: ("vless-reality-" + $port),
      listen: "0.0.0.0",
      port: ($port | tonumber),
      protocol: "vless",
      settings: {
        clients: [
          {
            id: $uuid,
            flow: "xtls-rprx-vision",
            email: $remark
          }
        ],
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          target: ($reality_domain + ":" + $reality_target_port),
          xver: 0,
          serverNames: [$reality_domain],
          privateKey: $private_key,
          publicKey: $public_key,
          maxTimeDiff: 70000,
          shortIds: [$short_id]
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"],
        routeOnly: true
      }
    }'
}

ss2022_inbound_json() {
  local port="$1"
  local password="$2"
  local remark="$3"

  jq -n \
    --arg port "${port}" \
    --arg method "${SS2022_METHOD}" \
    --arg password "${password}" \
    --arg remark "${remark}" \
    '{
      tag: ("shadowsocks-2022-" + $port),
      listen: "0.0.0.0",
      port: ($port | tonumber),
      protocol: "shadowsocks",
      settings: {
        method: $method,
        password: $password,
        network: "tcp,udp",
        level: 0,
        email: $remark
      }
    }'
}

append_inbound_json() {
  local config="$1"
  local inbound="$2"

  jq --argjson inbound "${inbound}" '.inbounds = ((.inbounds // []) + [$inbound])' <<<"${config}"
}

config_has_port_json() {
  local config="$1"
  local port="$2"

  jq -e --argjson port "${port}" 'any(.inbounds[]?; .port == $port)' <<<"${config}" >/dev/null
}

test_xray_config() {
  local config_file="$1"

  if "${XRAY_BIN}" run -test -config "${config_file}"; then
    return 0
  fi

  warn "当前 Xray 配置验证失败"
  return 1
}

set_config_permissions() {
  local config_file="$1"

  chmod 644 "${config_file}"
}

vless_reality_link() {
  local server="$1"
  local port="$2"
  local uuid="$3"
  local reality_domain="$4"
  local public_key="$5"
  local short_id="$6"
  local remark="$7"

  printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision#%s\n' \
    "${uuid}" \
    "${server}" \
    "${port}" \
    "$(urlencode "${reality_domain}")" \
    "$(urlencode "${public_key}")" \
    "$(urlencode "${short_id}")" \
    "$(urlencode "${remark}")"
}

ss2022_link() {
  local server="$1"
  local port="$2"
  local method="$3"
  local password="$4"
  local remark="$5"
  local userinfo

  userinfo="$(printf '%s:%s' "${method}" "${password}" | base64_urlsafe)"
  printf 'ss://%s@%s:%s#%s\n' \
    "${userinfo}" \
    "${server}" \
    "${port}" \
    "$(urlencode "${remark}")"
}

is_valid_port() {
  local port="$1"

  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value

  read -r -p "${prompt} [默认: ${default_value}]: " value
  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi

  printf '%s' "${value}"
}

prompt_port() {
  local prompt="$1"
  local default_value="$2"
  local value

  while true; do
    value="$(prompt_with_default "${prompt}" "${default_value}")"
    if is_valid_port "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "端口必须是 1-65535 的数字"
  done
}

detect_public_address() {
  local address=""

  if command_exists curl; then
    address="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi

  if [[ -z "${address}" ]] && command_exists hostname; then
    address="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ -z "${address}" ]]; then
    address="YOUR_SERVER_IP"
  fi

  printf '%s' "${address}"
}

generate_uuid() {
  if [[ -x "${XRAY_BIN}" ]]; then
    "${XRAY_BIN}" uuid
  elif command_exists uuidgen; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    die "无法生成 UUID，请先安装 Xray 或 uuidgen"
  fi
}

generate_ss2022_password() {
  require_command openssl
  openssl rand -base64 32
}

generate_short_id() {
  require_command openssl
  openssl rand -hex 8
}

generate_reality_keypair() {
  [[ -x "${XRAY_BIN}" ]] || die "找不到 Xray: ${XRAY_BIN}"

  local output private_key public_key
  output="$("${XRAY_BIN}" x25519)"
  private_key="$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"${output}")"
  public_key="$(awk -F': *' 'tolower($1) ~ /public/ || tolower($1) ~ /password/ {print $2; exit}' <<<"${output}")"

  if [[ -z "${private_key}" || -z "${public_key}" ]]; then
    printf '%s\n' "${output}" >&2
    die "解析 Xray x25519 输出失败"
  fi

  printf '%s %s\n' "${private_key}" "${public_key}"
}

install_dependencies() {
  require_root

  if ! command_exists apt-get; then
    die "当前脚本面向 Debian/Ubuntu，请在有 apt-get 的系统上运行"
  fi

  info "安装依赖: curl unzip jq openssl ca-certificates"
  apt-get update
  apt-get install -y curl unzip jq openssl ca-certificates
}

install_xray_core() {
  require_root
  install_dependencies

  if [[ -x "${XRAY_BIN}" ]]; then
    success "检测到 Xray 已安装: $(${XRAY_BIN} version | head -n 1)"
    return 0
  fi

  local installer
  installer="$(mktemp)"
  info "下载 Xray 官方安装脚本"
  curl -fsSL "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "${installer}"
  info "安装 Xray"
  bash "${installer}" install
  rm -f "${installer}"

  [[ -x "${XRAY_BIN}" ]] || die "Xray 安装后仍找不到 ${XRAY_BIN}"
  success "Xray 安装完成: $(${XRAY_BIN} version | head -n 1)"
}

read_config_or_default() {
  require_jq

  if [[ -f "${XRAY_CONFIG_PATH}" ]]; then
    ensure_base_sections_json "$(jq . "${XRAY_CONFIG_PATH}")"
  else
    default_config_json
  fi
}

write_config_checked() {
  require_root
  require_jq
  [[ -x "${XRAY_BIN}" ]] || die "找不到 Xray: ${XRAY_BIN}"

  local config="$1"
  local config_dir tmp_file backup_file
  config_dir="$(dirname "${XRAY_CONFIG_PATH}")"
  mkdir -p "${config_dir}"

  tmp_file="$(mktemp "${config_dir}/config.json.tmp.XXXXXX")"
  jq . <<<"${config}" >"${tmp_file}"

  info "验证 Xray 配置"
  if ! test_xray_config "${tmp_file}"; then
    rm -f "${tmp_file}"
    die "Xray 配置验证失败，未写入正式配置"
  fi

  if [[ -f "${XRAY_CONFIG_PATH}" ]]; then
    backup_file="${XRAY_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${XRAY_CONFIG_PATH}" "${backup_file}"
    success "已备份旧配置: ${backup_file}"
  fi

  mv "${tmp_file}" "${XRAY_CONFIG_PATH}"
  set_config_permissions "${XRAY_CONFIG_PATH}"

  if command_exists systemctl; then
    systemctl daemon-reload
    systemctl enable "${XRAY_SERVICE}"
    systemctl restart "${XRAY_SERVICE}"
    success "Xray 服务已重启"
  else
    warn "未找到 systemctl，请手动重启 Xray"
  fi
}

add_vless_reality() {
  require_root
  require_jq
  [[ -x "${XRAY_BIN}" ]] || die "找不到 Xray，请先选择安装 Xray 的菜单项"

  local port server_address reality_domain reality_target_port remark uuid keypair private_key public_key short_id
  local config inbound new_config link

  port="$(prompt_port "请输入 VLESS REALITY 监听端口" "${DEFAULT_PORT}")"
  server_address="$(prompt_with_default "请输入客户端连接地址/IP" "$(detect_public_address)")"
  reality_domain="$(prompt_with_default "请输入 REALITY 伪装域名/SNI" "${DEFAULT_REALITY_DOMAIN}")"
  reality_target_port="$(prompt_port "请输入 REALITY 目标端口" "${DEFAULT_PORT}")"
  remark="$(prompt_with_default "请输入节点名称" "vless-reality-${port}")"

  config="$(read_config_or_default)"
  if config_has_port_json "${config}" "${port}"; then
    die "配置中已存在端口 ${port} 的入站，请重新运行并选择其他端口"
  fi

  uuid="$(generate_uuid)"
  keypair="$(generate_reality_keypair)"
  private_key="$(awk '{print $1}' <<<"${keypair}")"
  public_key="$(awk '{print $2}' <<<"${keypair}")"
  short_id="$(generate_short_id)"

  inbound="$(vless_reality_inbound_json "${port}" "${uuid}" "${reality_domain}" "${reality_target_port}" "${private_key}" "${public_key}" "${short_id}" "${remark}")"
  new_config="$(append_inbound_json "${config}" "${inbound}")"
  write_config_checked "${new_config}"

  link="$(vless_reality_link "${server_address}" "${port}" "${uuid}" "${reality_domain}" "${public_key}" "${short_id}" "${remark}")"
  success "VLESS REALITY 已配置完成"
  printf '\n%s\n%s\n\n' "VLESS 链接:" "${link}"
}

add_ss2022() {
  require_root
  require_jq
  [[ -x "${XRAY_BIN}" ]] || die "找不到 Xray，请先选择安装 Xray 的菜单项"

  local port server_address remark password config inbound new_config link

  port="$(prompt_port "请输入 Shadowsocks 2022 监听端口" "${DEFAULT_PORT}")"
  server_address="$(prompt_with_default "请输入客户端连接地址/IP" "$(detect_public_address)")"
  remark="$(prompt_with_default "请输入节点名称" "ss2022-${port}")"

  config="$(read_config_or_default)"
  if config_has_port_json "${config}" "${port}"; then
    die "配置中已存在端口 ${port} 的入站，请重新运行并选择其他端口"
  fi

  password="$(generate_ss2022_password)"
  inbound="$(ss2022_inbound_json "${port}" "${password}" "${remark}")"
  new_config="$(append_inbound_json "${config}" "${inbound}")"
  write_config_checked "${new_config}"

  link="$(ss2022_link "${server_address}" "${port}" "${SS2022_METHOD}" "${password}" "${remark}")"
  success "Shadowsocks 2022 已配置完成"
  printf '\n%s\n%s\n\n' "SS 链接:" "${link}"
}

install_and_add_vless_reality() {
  install_xray_core
  add_vless_reality
}

install_and_add_ss2022() {
  install_xray_core
  add_ss2022
}

enable_bbr() {
  require_root

  local sysctl_file="/etc/sysctl.d/99-xray-tools-bbr.conf"
  cat >"${sysctl_file}" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl --system
  success "BBR 设置已写入: ${sysctl_file}"
  sysctl net.ipv4.tcp_congestion_control || true
}

print_menu() {
  cat <<'EOF'

================ Xray 快速安装配置 ================
1. 安装 Xray 并配置 VLESS-TCP-XTLS-Vision-REALITY
2. 安装 Xray 并配置 Shadowsocks 2022
3. 给已有 Xray 新增 VLESS-TCP-XTLS-Vision-REALITY
4. 给已有 Xray 新增 Shadowsocks 2022
5. 开启 BBR
0. 退出
===================================================
EOF
}

main_menu() {
  local choice

  while true; do
    print_menu
    read -r -p "请选择: " choice
    case "${choice}" in
      1)
        install_and_add_vless_reality
        ;;
      2)
        install_and_add_ss2022
        ;;
      3)
        add_vless_reality
        ;;
      4)
        add_ss2022
        ;;
      5)
        enable_bbr
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择，请重新输入"
        ;;
    esac
  done
}

if [[ "${XRAY_TOOLS_TESTING:-0}" != "1" ]]; then
  main_menu "$@"
fi
