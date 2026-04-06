#!/usr/bin/env bash
# Emby Proxy Alpine Lite
# 一个适用于 Alpine Linux / NAT VPS / 非标准端口环境的轻量级 Emby/Jellyfin 反代一键脚本。
#
# 功能：
# - DNS 验证申请证书（acme.sh）
# - 非标准 HTTPS 入口
# - HTTPS 上游回源
# - WebSocket / 长连接支持
# - 面向低配小鸡优化
#
# 适用场景：
# - Alpine Linux
# - 无 80/443 端口
# - NAT VPS / 高位端口映射
# - 自用 Emby/Jellyfin 反代
#
# 注意：
# - 客户端必须填写 https://域名:端口
# - 使用 Cloudflare 橙云时建议使用 2053 等支持的 HTTPS 端口
# - 如使用非 Cloudflare 支持端口，建议灰云（DNS only）

set -euo pipefail

TOOL_NAME="emby-proxy-alpine-fresh"
NGINX_MAIN="/etc/nginx/nginx.conf"
HTTP_D="/etc/nginx/http.d"
CONF_PREFIX="emby-lite-"
ACME_HOME="/root/.acme.sh"
CERT_HOME="/etc/nginx/certs"

need_root() {
  [ "$(id -u)" -eq 0 ] || {
    echo "请用 root 运行"
    exit 1
  }
}

prompt() {
  local var_name="$1"
  local text="$2"
  local default="${3:-}"
  local value=""
  if [ -n "$default" ]; then
    read -r -p "$text [$default]: " value || true
    value="${value:-$default}"
  else
    read -r -p "$text: " value || true
  fi
  printf -v "$var_name" '%s' "$value"
}

yesno() {
  local var_name="$1"
  local text="$2"
  local default="${3:-y}"
  local ans=""
  local hint="y/N"
  [ "$default" = "y" ] && hint="Y/n"
  read -r -p "$text [$hint]: " ans || true
  ans="${ans:-$default}"
  case "$ans" in
    y|Y|yes|YES) printf -v "$var_name" 'y' ;;
    *) printf -v "$var_name" 'n' ;;
  esac
}

strip_scheme() {
  local s="${1:-}"
  s="${s#http://}"
  s="${s#https://}"
  s="${s%%/}"
  echo "$s"
}

sanitize_name() {
  echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

is_port() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

is_valid_email() {
  local email="${1:-}"
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

ensure_deps() {
  echo "==> 安装依赖..."
  apk add --no-cache nginx bash curl ca-certificates openssl socat apache2-utils iproute2 >/dev/null
}

ensure_dirs() {
  mkdir -p /run/nginx
  mkdir -p "$HTTP_D"
  mkdir -p /var/log/nginx
  mkdir -p "$CERT_HOME"
}

backup_nginx_conf() {
  [ -f "$NGINX_MAIN" ] && cp -f "$NGINX_MAIN" "${NGINX_MAIN}.bak.$(date +%s)" || true
}

clean_old_emby_conf() {
  echo "==> 清理旧 emby-lite 配置..."
  rm -f "${HTTP_D}/${CONF_PREFIX}"*.conf 2>/dev/null || true
}

clean_old_acme_if_needed() {
  yesno RESET_ACME "是否清理旧 acme.sh 状态并全新签发证书（新机器建议选 y）" "y"
  if [ "$RESET_ACME" = "y" ]; then
    echo "==> 清理旧 acme.sh 状态..."
    rm -rf "$ACME_HOME"
  fi
}

install_or_init_acme_sh() {
  local acme_email="$1"

  if ! is_valid_email "$acme_email"; then
    echo "邮箱格式不合法: $acme_email"
    exit 1
  fi

  if [ ! -x "${ACME_HOME}/acme.sh" ]; then
    echo "==> 安装 acme.sh ..."
    curl -fsSL https://get.acme.sh | sh -s email="$acme_email"
  fi

  echo "==> 设置 acme.sh 默认 CA 为 Let's Encrypt ..."
  "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  echo "==> 注册/更新 ACME 账户邮箱 ..."
  "${ACME_HOME}/acme.sh" --register-account -m "$acme_email" --server letsencrypt
}

setup_dns_env() {
  local provider="$1"

  case "$provider" in
    cloudflare)
      prompt CF_Token "请输入 Cloudflare API Token"
      [ -n "${CF_Token:-}" ] || { echo "CF_Token 不能为空"; exit 1; }
      export CF_Token
      ;;
    aliyun)
      prompt Ali_Key "请输入阿里云 Ali_Key"
      prompt Ali_Secret "请输入阿里云 Ali_Secret"
      [ -n "${Ali_Key:-}" ] || { echo "Ali_Key 不能为空"; exit 1; }
      [ -n "${Ali_Secret:-}" ] || { echo "Ali_Secret 不能为空"; exit 1; }
      export Ali_Key Ali_Secret
      ;;
    dnspod)
      prompt DP_Id "请输入 DNSPod DP_Id"
      prompt DP_Key "请输入 DNSPod DP_Key"
      [ -n "${DP_Id:-}" ] || { echo "DP_Id 不能为空"; exit 1; }
      [ -n "${DP_Key:-}" ] || { echo "DP_Key 不能为空"; exit 1; }
      export DP_Id DP_Key
      ;;
    *)
      echo "不支持的 DNS 提供商: $provider"
      exit 1
      ;;
  esac
}

issue_cert() {
  local domain="$1"
  local provider="$2"

  echo "==> 申请证书: ${domain}"

  case "$provider" in
    cloudflare)
      "${ACME_HOME}/acme.sh" --issue --dns dns_cf -d "$domain" --keylength ec-256
      ;;
    aliyun)
      "${ACME_HOME}/acme.sh" --issue --dns dns_ali -d "$domain" --keylength ec-256
      ;;
    dnspod)
      "${ACME_HOME}/acme.sh" --issue --dns dns_dp -d "$domain" --keylength ec-256
      ;;
    *)
      echo "不支持的 DNS 提供商: $provider"
      exit 1
      ;;
  esac
}

install_cert() {
  local domain="$1"
  local cert_dir="${CERT_HOME}/${domain}"
  mkdir -p "$cert_dir"

  echo "==> 安装证书到 ${cert_dir}"

  "${ACME_HOME}/acme.sh" --install-cert -d "$domain" \
    --ecc \
    --fullchain-file "${cert_dir}/fullchain.cer" \
    --key-file "${cert_dir}/private.key" \
    --reloadcmd "rc-service nginx reload || rc-service nginx restart || true"
}

write_main_nginx_conf() {
  echo "==> 写入轻量 nginx.conf ..."
  cat > "$NGINX_MAIN" <<'EOF'
user nginx;
worker_processes 1;
pid /run/nginx/nginx.pid;

events {
    worker_connections 512;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    keepalive_timeout 15;
    keepalive_requests 100;

    client_body_timeout 10s;
    client_header_timeout 10s;
    send_timeout 30s;

    types_hash_max_size 2048;
    server_tokens off;

    access_log off;
    error_log /var/log/nginx/error.log warn;

    include /etc/nginx/http.d/*.conf;
}
EOF
}

write_proxy_conf() {
  local domain="$1"
  local listen_port="$2"
  local upstream_host="$3"
  local upstream_port="$4"
  local enable_auth="$5"
  local auth_user="$6"
  local auth_pass="$7"
  local skip_verify="$8"

  local conf_path="${HTTP_D}/${CONF_PREFIX}$(sanitize_name "$domain")-${listen_port}.conf"
  local htpasswd_file="/etc/nginx/.htpasswd-emby-lite-${listen_port}"
  local cert_dir="${CERT_HOME}/${domain}"

  if [ "$enable_auth" = "y" ]; then
    htpasswd -bc "$htpasswd_file" "$auth_user" "$auth_pass" >/dev/null
  fi

  local auth_block=""
  if [ "$enable_auth" = "y" ]; then
    auth_block=$(cat <<EOF
        auth_basic "Restricted";
        auth_basic_user_file ${htpasswd_file};
EOF
)
  fi

  local ssl_verify_block=""
  if [ "$skip_verify" = "y" ]; then
    ssl_verify_block="        proxy_ssl_verify off;"
  fi

  cat > "$conf_path" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen ${listen_port} ssl;
    listen [::]:${listen_port} ssl;
    server_name ${domain};

    ssl_certificate     ${cert_dir}/fullchain.cer;
    ssl_certificate_key ${cert_dir}/private.key;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    access_log off;
    error_log /var/log/nginx/emby-lite-${listen_port}.error.log warn;

    location / {
${auth_block}
        proxy_pass https://${upstream_host}:${upstream_port};
        proxy_http_version 1.1;

        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_connect_timeout 5s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_ssl_server_name on;
${ssl_verify_block}

        client_max_body_size 500m;
    }
}
EOF

  echo "$conf_path"
}

test_nginx() {
  echo "==> 检查 nginx 配置..."
  nginx -t
}

enable_start_nginx() {
  rc-update add nginx default >/dev/null 2>&1 || true
  rc-service nginx start >/dev/null 2>&1 || true
}

reload_nginx() {
  echo "==> 重载 nginx ..."
  rc-service nginx reload >/dev/null 2>&1 || rc-service nginx restart >/dev/null 2>&1 || nginx -s reload
}

show_result() {
  local domain="$1"
  local port="$2"

  echo
  echo "========================================"
  echo "部署完成"
  echo "最终地址: https://${domain}:${port}"
  echo
  echo "注意："
  echo "1. 客户端必须填 HTTPS"
  echo "2. 端口必须填 ${port}"
  echo "3. 如使用 Cloudflare，建议先灰云（DNS only）"
  echo "4. NAT 面板必须映射 公网${port} -> 本机${port}"
  echo "========================================"
  echo
}

main() {
  need_root
  ensure_deps
  ensure_dirs
  backup_nginx_conf

  echo "=== ${TOOL_NAME} ==="
  echo "适用：Alpine 新机器从零部署"
  echo

  prompt ACME_EMAIL "请输入用于申请证书的合法邮箱"
  is_valid_email "$ACME_EMAIL" || { echo "邮箱格式不合法"; exit 1; }

  prompt DOMAIN "入口域名（必须已解析到本机公网IP）"
  DOMAIN="$(strip_scheme "$DOMAIN")"
  [ -n "$DOMAIN" ] || { echo "域名不能为空"; exit 1; }

  prompt LISTEN_PORT "本机 HTTPS 监听端口（例如 2053 / 52443，不能是 80/443/8080/8443）" "52443"
  is_port "$LISTEN_PORT" || { echo "端口不合法"; exit 1; }

  prompt UPSTREAM_HOST "HTTPS 上游主机名或IP（不要带 https://）"
  UPSTREAM_HOST="$(strip_scheme "$UPSTREAM_HOST")"
  [ -n "$UPSTREAM_HOST" ] || { echo "上游主机不能为空"; exit 1; }

  prompt UPSTREAM_PORT "HTTPS 上游端口" "443"
  is_port "$UPSTREAM_PORT" || { echo "上游端口不合法"; exit 1; }

  echo "请选择 DNS 提供商："
  echo "1) cloudflare"
  echo "2) aliyun"
  echo "3) dnspod"
  read -r -p "输入序号: " DNS_CHOICE

  case "$DNS_CHOICE" in
    1) DNS_PROVIDER="cloudflare" ;;
    2) DNS_PROVIDER="aliyun" ;;
    3) DNS_PROVIDER="dnspod" ;;
    *) echo "无效选择"; exit 1 ;;
  esac

  setup_dns_env "$DNS_PROVIDER"

  yesno ENABLE_AUTH "是否启用 BasicAuth 额外门禁" "n"
  AUTH_USER="emby"
  AUTH_PASS=""
  if [ "$ENABLE_AUTH" = "y" ]; then
    prompt AUTH_USER "BasicAuth 用户名" "emby"
    prompt AUTH_PASS "BasicAuth 密码"
    [ -n "$AUTH_PASS" ] || { echo "密码不能为空"; exit 1; }
  fi

  yesno SKIP_VERIFY "如上游 HTTPS 证书异常/自签，是否跳过验证" "y"

  clean_old_emby_conf
  clean_old_acme_if_needed
  install_or_init_acme_sh "$ACME_EMAIL"
  issue_cert "$DOMAIN" "$DNS_PROVIDER"
  install_cert "$DOMAIN"
  write_main_nginx_conf
  conf_path="$(write_proxy_conf "$DOMAIN" "$LISTEN_PORT" "$UPSTREAM_HOST" "$UPSTREAM_PORT" "$ENABLE_AUTH" "$AUTH_USER" "$AUTH_PASS" "$SKIP_VERIFY")"

  echo "==> 已写入配置: $conf_path"

  test_nginx
  enable_start_nginx
  reload_nginx

  echo "==> 当前监听端口："
  ss -lntp | grep -E ":${LISTEN_PORT}\b" || true

  show_result "$DOMAIN" "$LISTEN_PORT"
}

main "$@"
