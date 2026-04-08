#!/usr/bin/env bash
# Emby Proxy Alpine Lite - Menu Edition
# Alpine / NAT VPS / 非标准端口 / DNS 验证 / HTTPS 上游 / 多站点共存

set -euo pipefail

TOOL_NAME="emby-proxy-alpine-lite"
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
    read -r -p "$text [$default]: " value </dev/tty || true
    value="${value:-$default}"
  else
    read -r -p "$text: " value </dev/tty || true
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
  read -r -p "$text [$hint]: " ans </dev/tty || true
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

choose_dns_provider() {
  echo "请选择 DNS 提供商："
  echo "1) cloudflare"
  echo "2) aliyun"
  echo "3) dnspod"
  read -r -p "输入序号: " DNS_CHOICE </dev/tty

  case "$DNS_CHOICE" in
    1) DNS_PROVIDER="cloudflare" ;;
    2) DNS_PROVIDER="aliyun" ;;
    3) DNS_PROVIDER="dnspod" ;;
    *) echo "无效选择"; return 1 ;;
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

conf_path_for_site() {
  local domain="$1"
  local port="$2"
  echo "${HTTP_D}/${CONF_PREFIX}$(sanitize_name "$domain")-${port}.conf"
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

  local conf_path
  conf_path="$(conf_path_for_site "$domain" "$listen_port")"
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
# META domain=${domain} port=${listen_port} upstream=${upstream_host}:${upstream_port} basicauth=${enable_auth}

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

site_exists() {
  local domain="$1"
  local port="$2"
  local conf
  conf="$(conf_path_for_site "$domain" "$port")"
  [ -f "$conf" ]
}

list_sites() {
  echo "=== 已有站点 ==="
  local found=0
  for f in "${HTTP_D}/${CONF_PREFIX}"*.conf; do
    [ -e "$f" ] || continue
    found=1
    local meta domain port upstream
    meta="$(grep -E '^# META ' "$f" | head -n1 || true)"
    domain="$(echo "$meta" | sed -n 's/.*domain=\([^ ]*\).*/\1/p')"
    port="$(echo "$meta" | sed -n 's/.*port=\([^ ]*\).*/\1/p')"
    upstream="$(echo "$meta" | sed -n 's/.*upstream=\([^ ]*\).*/\1/p')"
    echo "- 域名: ${domain:-未知} | 端口: ${port:-未知} | 上游: ${upstream:-未知}"
    echo "  配置: $f"
  done
  [ "$found" -eq 1 ] || echo "（空）"
  echo
}

init_system() {
  need_root
  ensure_deps
  ensure_dirs
  backup_nginx_conf

  prompt ACME_EMAIL "请输入用于申请证书的合法邮箱"
  is_valid_email "$ACME_EMAIL" || { echo "邮箱格式不合法"; return 1; }

  install_or_init_acme_sh "$ACME_EMAIL"
  write_main_nginx_conf
  test_nginx
  enable_start_nginx
  reload_nginx

  echo "==> 初始化完成"
  echo
}

add_site() {
  need_root
  ensure_deps
  ensure_dirs

  if [ ! -x "${ACME_HOME}/acme.sh" ]; then
    echo "未检测到 acme.sh，请先执行「初始化系统环境」"
    return 1
  fi

  if [ ! -f "$NGINX_MAIN" ]; then
    echo "未检测到 nginx 主配置，请先执行「初始化系统环境」"
    return 1
  fi

  prompt DOMAIN "请输入入口域名（必须已解析到本机公网IP）"
  DOMAIN="$(strip_scheme "$DOMAIN")"
  [ -n "$DOMAIN" ] || { echo "域名不能为空"; return 1; }

  prompt LISTEN_PORT "请输入 HTTPS 监听端口（如 2053 / 52443）" "52443"
  is_port "$LISTEN_PORT" || { echo "端口不合法"; return 1; }

  prompt UPSTREAM_HOST "请输入 HTTPS 上游主机名或IP（不要带 https://）"
  UPSTREAM_HOST="$(strip_scheme "$UPSTREAM_HOST")"
  [ -n "$UPSTREAM_HOST" ] || { echo "上游主机不能为空"; return 1; }

  prompt UPSTREAM_PORT "请输入 HTTPS 上游端口" "443"
  is_port "$UPSTREAM_PORT" || { echo "上游端口不合法"; return 1; }

  if site_exists "$DOMAIN" "$LISTEN_PORT"; then
    yesno OVERWRITE "检测到相同 域名+端口 配置已存在，是否覆盖" "n"
    [ "$OVERWRITE" = "y" ] || { echo "已取消"; return 0; }
  fi

  choose_dns_provider || return 1
  setup_dns_env "$DNS_PROVIDER"

  yesno ENABLE_AUTH "是否启用 BasicAuth 额外门禁" "n"
  AUTH_USER="emby"
  AUTH_PASS=""
  if [ "$ENABLE_AUTH" = "y" ]; then
    prompt AUTH_USER "BasicAuth 用户名" "emby"
    prompt AUTH_PASS "BasicAuth 密码"
    [ -n "$AUTH_PASS" ] || { echo "密码不能为空"; return 1; }
  fi

  yesno SKIP_VERIFY "如上游 HTTPS 证书异常/自签，是否跳过验证" "y"

  issue_cert "$DOMAIN" "$DNS_PROVIDER"
  install_cert "$DOMAIN"
  conf_path="$(write_proxy_conf "$DOMAIN" "$LISTEN_PORT" "$UPSTREAM_HOST" "$UPSTREAM_PORT" "$ENABLE_AUTH" "$AUTH_USER" "$AUTH_PASS" "$SKIP_VERIFY")"

  echo "==> 已写入配置: $conf_path"
  test_nginx
  enable_start_nginx
  reload_nginx

  echo "==> 当前监听端口："
  ss -lntp | grep -E ":${LISTEN_PORT}\b" || true

  echo
  echo "新增完成，访问地址："
  echo "https://${DOMAIN}:${LISTEN_PORT}"
  echo
}

remove_site() {
  need_root

  list_sites
  prompt DOMAIN "请输入要删除的域名"
  DOMAIN="$(strip_scheme "$DOMAIN")"
  [ -n "$DOMAIN" ] || { echo "域名不能为空"; return 1; }

  prompt LISTEN_PORT "请输入该域名对应的监听端口"
  is_port "$LISTEN_PORT" || { echo "端口不合法"; return 1; }

  local conf
  conf="$(conf_path_for_site "$DOMAIN" "$LISTEN_PORT")"

  if [ ! -f "$conf" ]; then
    echo "未找到配置文件：$conf"
    return 1
  fi

  yesno CONFIRM_REMOVE "确认删除该站点配置" "n"
  [ "$CONFIRM_REMOVE" = "y" ] || { echo "已取消"; return 0; }

  rm -f "$conf"
  rm -f "/etc/nginx/.htpasswd-emby-lite-${LISTEN_PORT}" 2>/dev/null || true

  yesno REMOVE_CERT "是否同时删除该域名证书目录 ${CERT_HOME}/${DOMAIN}" "n"
  if [ "$REMOVE_CERT" = "y" ]; then
    rm -rf "${CERT_HOME}/${DOMAIN}"
  fi

  test_nginx
  reload_nginx
  echo "==> 删除完成"
  echo
}

uninstall_all() {
  need_root
  yesno CONFIRM "确认卸载本项目所有站点与证书" "n"
  [ "$CONFIRM" = "y" ] || { echo "已取消"; return 0; }

  rm -f "${HTTP_D}/${CONF_PREFIX}"*.conf 2>/dev/null || true
  rm -f /etc/nginx/.htpasswd-emby-lite-* 2>/dev/null || true
  rm -rf "$CERT_HOME"/*
  rm -rf "$ACME_HOME"

  if ls /etc/nginx/nginx.conf.bak.* >/dev/null 2>&1; then
    latest_bak="$(ls -1t /etc/nginx/nginx.conf.bak.* | head -n1)"
    yesno RESTORE_MAIN "检测到 nginx.conf 备份，是否恢复最近一次备份" "y"
    if [ "$RESTORE_MAIN" = "y" ]; then
      cp -f "$latest_bak" /etc/nginx/nginx.conf
    fi
  fi

  if nginx -t >/dev/null 2>&1; then
    reload_nginx
  else
    rc-service nginx stop >/dev/null 2>&1 || true
  fi

  yesno REMOVE_NGINX "是否卸载 nginx 软件包（仅当本机不再需要 nginx 时选择 y）" "n"
  if [ "$REMOVE_NGINX" = "y" ]; then
    rc-service nginx stop >/dev/null 2>&1 || true
    rc-update del nginx default >/dev/null 2>&1 || true
    apk del nginx >/dev/null 2>&1 || true
  fi

  echo "==> 卸载完成"
  echo
}

main_menu() {
  need_root
  while true; do
    echo "=== ${TOOL_NAME} ==="
    echo "1) 初始化系统环境"
    echo "2) 新增反代站点"
    echo "3) 删除反代站点"
    echo "4) 查看已有站点"
    echo "5) 卸载本项目"
    echo "0) 退出"
    read -r -p "请选择: " CHOICE </dev/tty
    case "$CHOICE" in
      1) init_system ;;
      2) add_site ;;
      3) remove_site ;;
      4) list_sites ;;
      5) uninstall_all ;;
      0) exit 0 ;;
      *) echo "无效选择"; echo ;;
    esac
  done
}

main_menu "$@"
