#!/usr/bin/env bash
# Hysteria 2 + Cloudflare WARP selective routing installer
# Target: Debian/Ubuntu supported by Cloudflare's repository. Verified on Debian 12.
# Default policy: Google/YouTube -> WARP SOCKS5, everything else -> direct IPv4.

set -Eeuo pipefail
umask 077

HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.10.0}"
INSTALLER_VERSION="1.1.0"
HY2_PORT_START="${HY2_PORT_START:-40000}"
HY2_PORT_END="${HY2_PORT_END:-42000}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-41080}"
HY2_SNI="${HY2_SNI:-www.bing.com}"
HY2_MASQUERADE_URL="${HY2_MASQUERADE_URL:-https://www.bing.com/}"
DIRECT_MODE="${DIRECT_MODE:-4}"
FORCE_NEW_CERT="${FORCE_NEW_CERT:-0}"

CONFIG_DIR=/etc/hysteria
CONFIG_FILE=/etc/hysteria/config.yaml
SERVICE_FILE=/etc/systemd/system/hysteria-server.service
SYSCTL_FILE=/etc/sysctl.d/99-hysteria-udp.conf
LINKS_FILE=/root/hy2-client-links.txt
CLIENT_CONFIG_FILE=/root/hy2-client-config.yaml
BACKUP_ROOT=/root/hy2-warp-backups

log() { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[1;31m[错误] %s\033[0m\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 运行。"
  command -v systemctl >/dev/null || die "本脚本需要 systemd。"
  command -v apt-get >/dev/null || die "目前只支持 Debian/Ubuntu。"
}

validate_settings() {
  [[ "$HY2_PORT_START" =~ ^[0-9]+$ && "$HY2_PORT_END" =~ ^[0-9]+$ ]] || die "HY2 端口必须是数字。"
  (( HY2_PORT_START >= 1 && HY2_PORT_END <= 65535 && HY2_PORT_START <= HY2_PORT_END )) || die "HY2 端口范围无效。"
  [[ "$WARP_PROXY_PORT" =~ ^[0-9]+$ ]] && (( WARP_PROXY_PORT >= 1 && WARP_PROXY_PORT <= 65535 )) || die "WARP 端口无效。"
  [[ "$DIRECT_MODE" =~ ^(auto|64|46|6|4)$ ]] || die "DIRECT_MODE 只能是 auto、64、46、6 或 4。"
  [[ "$HY2_SNI" =~ ^[A-Za-z0-9.-]+$ ]] || die "HY2_SNI 格式无效。"
  [[ "$HY2_MASQUERADE_URL" =~ ^https:// ]] || die "伪装网址必须以 https:// 开头。"
}

backup_current() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  [[ -d "$CONFIG_DIR" ]] && cp -a "$CONFIG_DIR" "$BACKUP_DIR/etc-hysteria"
  [[ -f "$SERVICE_FILE" ]] && cp -a "$SERVICE_FILE" "$BACKUP_DIR/hysteria-server.service"
  [[ -f "$SYSCTL_FILE" ]] && cp -a "$SYSCTL_FILE" "$BACKUP_DIR/99-hysteria-udp.conf"
  [[ -f "$LINKS_FILE" ]] && cp -a "$LINKS_FILE" "$BACKUP_DIR/hy2-client-links.txt"
  [[ -f "$CLIENT_CONFIG_FILE" ]] && cp -a "$CLIENT_CONFIG_FILE" "$BACKUP_DIR/hy2-client-config.yaml"
  printf '%s\n' "$BACKUP_DIR"
}

restore_hysteria_backup() {
  warn "新配置启动失败，正在恢复 Hysteria 原配置。"
  if [[ -d "$BACKUP_DIR/etc-hysteria" ]]; then
    rm -rf -- "$CONFIG_DIR"
    cp -a "$BACKUP_DIR/etc-hysteria" "$CONFIG_DIR"
  fi
  if [[ -f "$BACKUP_DIR/hysteria-server.service" ]]; then
    cp -a "$BACKUP_DIR/hysteria-server.service" "$SERVICE_FILE"
  fi
  systemctl daemon-reload
  systemctl restart hysteria-server.service || true
}

install_base_packages() {
  log "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg iproute2 lsb-release openssl nftables
}

install_hysteria() {
  log "从 Hysteria 官方安装器安装固定版本 $HYSTERIA_VERSION"
  local temp_dir
  temp_dir="$(mktemp -d)"
  curl -fsSL https://get.hy2.sh/ -o "$temp_dir/hysteria-install.sh"
  HYSTERIA_USER=hysteria bash "$temp_dir/hysteria-install.sh" --version "$HYSTERIA_VERSION"
  rm -rf -- "$temp_dir"
  command -v hysteria >/dev/null || [[ -x /usr/local/bin/hysteria ]] || die "Hysteria 安装失败。"
}

install_warp() {
  log "从 Cloudflare 官方软件源安装 WARP"
  local codename temp_key
  # shellcheck disable=SC1091
  . /etc/os-release
  codename="${VERSION_CODENAME:-}"
  [[ -n "$codename" ]] || codename="$(lsb_release -cs)"
  temp_key="$(mktemp)"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output "$temp_key"
  install -m 0644 "$temp_key" /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  rm -f -- "$temp_key"
  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$codename" \
    > /etc/apt/sources.list.d/cloudflare-client.list
  apt-get update
  apt-get install -y cloudflare-warp
  systemctl enable --now warp-svc.service
}

warp() {
  warp-cli --accept-tos "$@"
}

configure_warp_proxy() {
  log "配置 WARP 为本地代理模式（不接管 VPS 默认路由）"
  if ! warp registration show >/dev/null 2>&1; then
    warp registration new >/dev/null 2>&1 || warp register >/dev/null
  fi
  warp disconnect >/dev/null 2>&1 || true
  warp tunnel protocol set MASQUE >/dev/null
  warp mode proxy >/dev/null
  warp proxy port "$WARP_PROXY_PORT" >/dev/null
  warp connect >/dev/null

  local i
  for i in {1..20}; do
    if warp status 2>/dev/null | grep -qi 'Connected'; then
      return 0
    fi
    sleep 1
  done
  die "WARP 未能连接，请运行：warp-cli --accept-tos status"
}

read_or_create_password() {
  if [[ -z "${HY2_PASSWORD:-}" && -f "$CONFIG_FILE" ]]; then
    HY2_PASSWORD="$(sed -n 's/^[[:space:]]*password:[[:space:]]*"\{0,1\}\([^"[:space:]]\+\)"\{0,1\}[[:space:]]*$/\1/p' "$CONFIG_FILE" | head -n 1)"
  fi
  [[ -n "${HY2_PASSWORD:-}" ]] || HY2_PASSWORD="$(openssl rand -hex 24)"
  [[ "$HY2_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]] || die "HY2_PASSWORD 只能包含英文字母、数字和 . _ ~ -，以免破坏 YAML 或节点链接。"
}

create_certificate() {
  local renew_cert="$FORCE_NEW_CERT"
  mkdir -p "$CONFIG_DIR"
  if [[ ! -s "$CONFIG_DIR/server.crt" || ! -s "$CONFIG_DIR/server.key" ]]; then
    renew_cert=1
  elif ! openssl x509 -in "$CONFIG_DIR/server.crt" -noout -ext subjectAltName 2>/dev/null | grep -Fq "DNS:${HY2_SNI}"; then
    renew_cert=1
  fi
  if [[ "$renew_cert" == 1 ]]; then
    log "生成带 SAN 的长期自签名 TLS 证书"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 3650 \
      -keyout "$CONFIG_DIR/server.key" \
      -out "$CONFIG_DIR/server.crt" \
      -subj "/CN=$HY2_SNI" \
      -addext "subjectAltName=DNS:$HY2_SNI" \
      -addext "keyUsage=digitalSignature" \
      -addext "extendedKeyUsage=serverAuth"
  fi
}

write_hysteria_config() {
  log "写入 Hysteria：Google/YouTube 走 WARP，其余 IPv4 直连"
  getent group hysteria >/dev/null || groupadd --system hysteria
  id hysteria >/dev/null 2>&1 || useradd --system --gid hysteria --home-dir /var/lib/hysteria --create-home --shell /usr/sbin/nologin hysteria
  install -d -m 0750 -o root -g hysteria "$CONFIG_DIR"
  create_certificate

  local temp_config
  temp_config="$(mktemp)"
  cat > "$temp_config" <<EOF
listen: :${HY2_PORT_START}-${HY2_PORT_END}

tls:
  cert: ${CONFIG_DIR}/server.crt
  key: ${CONFIG_DIR}/server.key
  sniGuard: strict

auth:
  type: password
  password: "${HY2_PASSWORD}"

resolver:
  type: https
  https:
    addr: 1.1.1.1:443
    timeout: 10s
    sni: cloudflare-dns.com

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: true

outbounds:
  - name: direct
    type: direct
    direct:
      mode: ${DIRECT_MODE}
  - name: warp
    type: socks5
    socks5:
      addr: 127.0.0.1:${WARP_PROXY_PORT}

acl:
  inline:
    - warp(suffix:google.com)
    - warp(suffix:googleapis.com)
    - warp(suffix:gstatic.com)
    - warp(suffix:googleusercontent.com)
    - warp(suffix:youtube.com)
    - warp(suffix:youtu.be)
    - warp(suffix:ytimg.com)
    - warp(suffix:ggpht.com)
    - direct(all)

masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE_URL}
    rewriteHost: true
EOF
  install -m 0640 -o root -g hysteria "$temp_config" "$CONFIG_FILE"
  rm -f -- "$temp_config"
  chown root:hysteria "$CONFIG_DIR/server.crt" "$CONFIG_DIR/server.key"
  chmod 0640 "$CONFIG_DIR/server.crt" "$CONFIG_DIR/server.key"
}

write_systemd_service() {
  log "写入 systemd 服务和 UDP 缓冲设置"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria Server Service (config.yaml)
Wants=network-online.target
After=network-online.target warp-svc.service

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config ${CONFIG_FILE}
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SYSCTL_FILE" <<'EOF'
# Hysteria/QUIC UDP socket buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  sysctl --system >/dev/null
  systemctl daemon-reload
  systemctl enable hysteria-server.service >/dev/null
}

open_firewall_if_needed() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "放行 UFW UDP 端口范围"
    ufw allow "${HY2_PORT_START}:${HY2_PORT_END}/udp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    log "放行 firewalld UDP 端口范围"
    firewall-cmd --permanent --add-port="${HY2_PORT_START}-${HY2_PORT_END}/udp"
    firewall-cmd --reload
  fi
}

start_and_verify() {
  log "启动并检查服务"
  if ! systemctl restart hysteria-server.service; then
    journalctl -u hysteria-server.service -n 50 --no-pager >&2 || true
    restore_hysteria_backup
    die "Hysteria 启动失败，已尝试恢复旧配置；备份位于 $BACKUP_DIR"
  fi
  systemctl is-active --quiet hysteria-server.service || die "Hysteria 服务未运行。"
  systemctl is-active --quiet warp-svc.service || die "WARP 服务未运行。"
  ss -lunp | grep -q ":${HY2_PORT_START}[[:space:]]" || die "未检测到 Hysteria UDP 监听端口。"

  if ! curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:${WARP_PROXY_PORT}" \
      https://www.cloudflare.com/cdn-cgi/trace | grep -q '^warp=on'; then
    warn "WARP 服务已连接，但 SOCKS5 出口自检未得到 warp=on；请稍后运行文档中的检查命令。"
  fi
}

url_encode() {
  local value="$1" out='' i char hex
  for ((i=0; i<${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) out+="$char" ;;
      *) printf -v hex '%%%02X' "'$char"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

write_client_links() {
  local ipv4 ipv6 encoded_password host4 host6 cert_pin
  ipv4="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  ipv6="$(curl -6fsS --max-time 5 https://api64.ipify.org || true)"
  encoded_password="$(url_encode "$HY2_PASSWORD")"
  cert_pin="$(openssl x509 -in "$CONFIG_DIR/server.crt" -noout -fingerprint -sha256 \
    | sed 's/^.*=//; s/://g' | tr '[:upper:]' '[:lower:]')"
  [[ "$cert_pin" =~ ^[0-9a-f]{64}$ ]] || die "无法生成有效的 TLS 证书 SHA-256 指纹。"
  host4="$ipv4"
  [[ -n "$host4" ]] || host4="你的服务器IPv4"

  {
    printf '# 推荐：单端口 + 证书指纹（PassWall2 优先测试）\n'
    printf 'hysteria2://%s@%s:%s/?insecure=1&pinSHA256=%s&sni=%s#HY2-Secure-Compatible\n\n' "$encoded_password" "$host4" "$HY2_PORT_START" "$cert_pin" "$HY2_SNI"
    printf '# 推荐：Hysteria2 官方端口跳跃格式\n'
    printf 'hysteria2://%s@%s:%s-%s/?insecure=1&pinSHA256=%s&sni=%s#HY2-Official-Port-Hopping\n\n' "$encoded_password" "$host4" "$HY2_PORT_START" "$HY2_PORT_END" "$cert_pin" "$HY2_SNI"
    printf '# 第三方兼容：部分 PassWall2/Clash 使用 mport 参数（不是 Hysteria2 官方 URI 参数）\n'
    printf 'hysteria2://%s@%s:%s/?insecure=1&pinSHA256=%s&sni=%s&mport=%s-%s#HY2-MPort-Compatible\n\n' "$encoded_password" "$host4" "$HY2_PORT_START" "$cert_pin" "$HY2_SNI" "$HY2_PORT_START" "$HY2_PORT_END"
    printf '# 旧客户端兜底：不支持 pinSHA256 时才使用，抗中间人攻击能力较弱\n'
    printf 'hysteria2://%s@%s:%s/?insecure=1&sni=%s#HY2-Legacy-Compatible\n' "$encoded_password" "$host4" "$HY2_PORT_START" "$HY2_SNI"
    if [[ -n "$ipv6" ]]; then
      host6="[$ipv6]"
      printf '\n# IPv6 单端口 + 证书指纹\n'
      printf 'hysteria2://%s@%s:%s/?insecure=1&pinSHA256=%s&sni=%s#HY2-IPv6-Secure\n' "$encoded_password" "$host6" "$HY2_PORT_START" "$cert_pin" "$HY2_SNI"
    fi
  } > "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"

  cat > "$CLIENT_CONFIG_FILE" <<EOF
# Hysteria2 官方客户端配置；包含节点密码，请勿公开。
server: ${host4}:${HY2_PORT_START}-${HY2_PORT_END}
auth: "${HY2_PASSWORD}"
tls:
  sni: ${HY2_SNI}
  insecure: true
  pinSHA256: ${cert_pin}
transport:
  type: udp
  udp:
    minHopInterval: 15s
    maxHopInterval: 45s
EOF
  chmod 0600 "$CLIENT_CONFIG_FILE"
}

print_result() {
  log "安装完成"
  printf 'Installer:  v%s\n' "$INSTALLER_VERSION"
  printf 'Hysteria: %s\n' "$(/usr/local/bin/hysteria version 2>/dev/null | head -n 1 || true)"
  printf 'WARP:      %s\n' "$(warp status 2>/dev/null | tr '\n' ' ' || true)"
  printf '备份目录:  %s\n' "$BACKUP_DIR"
  printf '节点文件:  %s（权限 600，请勿公开）\n\n' "$LINKS_FILE"
  printf '官方配置:  %s（权限 600，请勿公开）\n\n' "$CLIENT_CONFIG_FILE"
  cat "$LINKS_FILE"
  printf '\n安全提醒：不要把上面的节点链接、密码或订阅地址公开转发。\n'
}

main() {
  require_root
  validate_settings
  install_base_packages
  BACKUP_DIR="$(backup_current)"
  read_or_create_password
  install_hysteria
  install_warp
  configure_warp_proxy
  write_hysteria_config
  write_systemd_service
  open_firewall_if_needed
  start_and_verify
  write_client_links
  print_result
}

main "$@"
