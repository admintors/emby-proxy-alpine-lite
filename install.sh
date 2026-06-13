#!/usr/bin/env bash
# Emby Proxy Alpine Lite - Multi-Mode Edition
# 轻量 / Alpine / Debian / NAT VPS / DNS 验证 / 多站点共存 / 多模式反代

set -euo pipefail

TOOL_NAME="emby-proxy-alpine-lite"
NGINX_MAIN="/etc/nginx/nginx.conf"
CONF_PREFIX="emby-lite-"
ACME_HOME="/root/.acme.sh"
CERT_HOME="/etc/nginx/certs"
HTTP_D="/etc/nginx/http.d"
CONF_D="/etc/nginx/conf.d"
SITE_CONF_DIR=""
NGINX_USER="nginx"
MEDIA_PATH_REGEX='^/(Videos|emby/videos|Audio|PlaybackInfo|Playback|LiveTv|Items/.*/Download)'

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

is_domain_like() {
  local s="${1:-}"
  [ -n "$s" ] || return 1
  [[ "$s" =~ ^[A-Za-z0-9._:-]+$ ]]
}

choose_site_conf_dir() {
  if [ -d "$HTTP_D" ]; then
    SITE_CONF_DIR="$HTTP_D"
  elif [ -d "$CONF_D" ]; then
    SITE_CONF_DIR="$CONF_D"
  else
    SITE_CONF_DIR="$HTTP_D"
  fi
}

choose_nginx_user() {
  if id -u nginx >/dev/null 2>&1; then
    NGINX_USER="nginx"
  elif id -u www-data >/dev/null 2>&1; then
    NGINX_USER="www-data"
  else
    NGINX_USER="nobody"
  fi
}

is_alpine() {
  [ -f /etc/alpine-release ]
}

pkg_install() {
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@" >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y "$@" >/dev/null
  else
    echo "不支持的系统：未找到 apk 或 apt-get"
    exit 1
  fi
}

pkg_remove() {
  if command -v apk >/dev/null 2>&1; then
    apk del "$@" >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get remove -y "$@" >/dev/null 2>&1 || true
    apt-get purge -y "$@" >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
  fi
}

service_enable_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
  elif command -v rc-update >/dev/null 2>&1; then
    rc-update add nginx default >/dev/null 2>&1 || true
  fi
}

service_start_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start nginx >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service nginx start >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service nginx start >/dev/null 2>&1 || true
  else
    nginx >/dev/null 2>&1 || true
  fi
}

service_stop_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop nginx >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service nginx stop >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service nginx stop >/dev/null 2>&1 || true
  else
    nginx -s stop >/dev/null 2>&1 || true
  fi
}

reload_nginx() {
  echo "==> 重载 nginx ..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || nginx -s reload
  elif command -v service >/dev/null 2>&1; then
    service nginx reload >/dev/null 2>&1 || service nginx restart >/dev/null 2>&1 || nginx -s reload
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service nginx reload >/dev/null 2>&1 || rc-service nginx restart >/dev/null 2>&1 || nginx -s reload
  else
    nginx -s reload
  fi
}

enable_start_nginx() {
  service_enable_nginx
  service_start_nginx
}

ensure_deps() {
  echo "==> 安装依赖..."
  if command -v apk >/dev/null 2>&1; then
    pkg_install nginx bash curl ca-certificates openssl socat apache2-utils iproute2
  elif command -v apt-get >/dev/null 2>&1; then
    pkg_install nginx bash curl ca-certificates openssl socat apache2-utils iproute2
  fi
}

ensure_dirs() {
  mkdir -p /run/nginx
  mkdir -p "$HTTP_D"
  mkdir -p "$CONF_D"
  mkdir -p /var/log/nginx
  mkdir -p "$CERT_HOME"
  choose_site_conf_dir
  choose_nginx_user
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
    --reloadcmd "nginx -t && (systemctl reload nginx || service nginx reload || rc-service nginx reload || nginx -s reload || true)"
}

write_main_nginx_conf() {
  echo "==> 写入轻量 nginx.conf ..."
  cat > "$NGINX_MAIN" <<EOF
user ${NGINX_USER};
worker_processes 1;
pid /run/nginx/nginx.pid;

error_log /var/log/nginx/error.log warn;

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

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/http.d/*.conf;
}
EOF
}

conf_path_for_site() {
  local domain="$1"
  local port="$2"
  choose_site_conf_dir
  echo "${SITE_CONF_DIR}/${CONF_PREFIX}$(sanitize_name "$domain")-${port}.conf"
}

htpasswd_path_for_site() {
  local domain="$1"
  local port="$2"
  echo "/etc/nginx/.htpasswd-emby-lite-$(sanitize_name "$domain")-${port}"
}

proxy_ssl_verify_block() {
  local skip_verify="$1"
  if [ "$skip_verify" = "y" ]; then
    cat <<'EOF'
        proxy_ssl_verify off;
EOF
  else
    cat <<'EOF'
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
EOF
  fi
}

render_auth_block() {
  local enable_auth="$1"
  local auth_path="$2"
  if [ "$enable_auth" = "y" ]; then
    cat <<EOF
    auth_basic "Restricted";
    auth_basic_user_file ${auth_path};
EOF
  fi
}

render_host_header_line() {
  local mode="$1"
  local upstream_host="$2"
  local custom_host="$3"
  case "$mode" in
    preserve)
      echo 'proxy_set_header Host $host;'
      ;;
    custom)
      echo "proxy_set_header Host ${custom_host};"
      ;;
    upstream|*)
      echo "proxy_set_header Host ${upstream_host};"
      ;;
  esac
}

render_proxy_common_block() {
  local ssl_verify_block="$1"
  cat <<EOF
        proxy_http_version 1.1;
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
EOF
}

render_proxy_stream_extra_block() {
  cat <<'EOF'
        proxy_max_temp_file_size 0;
        proxy_force_ranges on;
        add_header X-Accel-Buffering "no" always;
        gzip off;
EOF
}

choose_proxy_mode() {
  echo "请选择反代模式："
  echo "1) 标准全站反代"
  echo "2) 前后端分离反代（前端/API 与媒体流分离）"
  echo "3) 播放流分流反代（默认走主站，播放相关路径走媒体上游）"
  echo "4) 流式传输优化模式"
  read -r -p "输入序号: " MODE_CHOICE </dev/tty
  case "$MODE_CHOICE" in
    1) PROXY_MODE="standard" ;;
    2) PROXY_MODE="split_front_media" ;;
    3) PROXY_MODE="media_only_split" ;;
    4) PROXY_MODE="stream_http" ;;
    *) echo "无效选择"; return 1 ;;
  esac
}

choose_upstream_scheme() {
  local var_name="$1"
  local title="$2"
  echo "$title"
  echo "1) https"
  echo "2) http"
  read -r -p "输入序号 [1]: " _scheme </dev/tty || true
  _scheme="${_scheme:-1}"
  case "$_scheme" in
    1) printf -v "$var_name" 'https' ;;
    2) printf -v "$var_name" 'http' ;;
    *) echo "无效选择"; return 1 ;;
  esac
}

choose_host_header_mode() {
  local prefix="$1"
  local target_host="$2"
  echo "请选择 ${prefix} Host 头策略："
  echo "1) 使用上游主机名（推荐）"
  echo "2) 保持入口域名（\$host）"
  echo "3) 自定义 Host"
  read -r -p "输入序号 [1]: " _mode </dev/tty || true
  _mode="${_mode:-1}"
  case "$_mode" in
    1)
      printf -v "${prefix}_HOST_MODE" 'upstream'
      printf -v "${prefix}_HOST_CUSTOM" ''
      ;;
    2)
      printf -v "${prefix}_HOST_MODE" 'preserve'
      printf -v "${prefix}_HOST_CUSTOM" ''
      ;;
    3)
      printf -v "${prefix}_HOST_MODE" 'custom'
      prompt "${prefix}_HOST_CUSTOM" "请输入自定义 Host" "$target_host"
      ;;
    *) echo "无效选择"; return 1 ;;
  esac
}

choose_media_path_preset() {
  echo "请选择媒体流路径规则预设："
  echo "1) Emby（默认）"
  echo "2) Jellyfin"
  echo "3) 自定义正则"
  read -r -p "输入序号 [1]: " PATH_PRESET_CHOICE </dev/tty || true
  PATH_PRESET_CHOICE="${PATH_PRESET_CHOICE:-1}"
  case "$PATH_PRESET_CHOICE" in
    1)
      MEDIA_PATH_PRESET="emby"
      MEDIA_PATH_REGEX='^/(Videos|emby/videos|Audio|PlaybackInfo|Playback|LiveTv|Items/.*/Download)'
      ;;
    2)
      MEDIA_PATH_PRESET="jellyfin"
      MEDIA_PATH_REGEX='^/(Videos|Audio|Items/.*/Download|websocket|socket|LiveTv|Sessions/.*/Playing)'
      ;;
    3)
      MEDIA_PATH_PRESET="custom"
      prompt MEDIA_PATH_REGEX "请输入自定义媒体流路径正则" '^/(Videos|emby/videos|Audio|PlaybackInfo|Playback|LiveTv|Items/.*/Download)'
      [ -n "$MEDIA_PATH_REGEX" ] || { echo "自定义正则不能为空"; return 1; }
      ;;
    *)
      echo "无效选择"
      return 1
      ;;
  esac
}

collect_common_site_params() {
  prompt DOMAIN "请输入入口域名（必须已解析到本机公网IP）"
  DOMAIN="$(strip_scheme "$DOMAIN")"
  [ -n "$DOMAIN" ] || { echo "域名不能为空"; return 1; }

  prompt LISTEN_PORT "请输入 HTTPS 监听端口（如 2053 / 52443）" "52443"
  is_port "$LISTEN_PORT" || { echo "端口不合法"; return 1; }

  if site_exists "$DOMAIN" "$LISTEN_PORT"; then
    yesno OVERWRITE "检测到相同 域名+端口 配置已存在，是否覆盖" "n"
    [ "$OVERWRITE" = "y" ] || { echo "已取消"; return 1; }
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
}

collect_standard_params() {
  choose_upstream_scheme UPSTREAM_SCHEME "请选择标准模式上游协议："
  prompt UPSTREAM_HOST "请输入上游主机名或IP（不要带 http:// 或 https://）"
  UPSTREAM_HOST="$(strip_scheme "$UPSTREAM_HOST")"
  [ -n "$UPSTREAM_HOST" ] || { echo "上游主机不能为空"; return 1; }
  prompt UPSTREAM_PORT "请输入上游端口" "$([ "$UPSTREAM_SCHEME" = "https" ] && echo 443 || echo 80)"
  is_port "$UPSTREAM_PORT" || { echo "上游端口不合法"; return 1; }
  if [ "$UPSTREAM_SCHEME" = "https" ]; then
    yesno SKIP_VERIFY "如上游 HTTPS 证书异常/自签，是否跳过验证" "y"
  else
    SKIP_VERIFY="n"
  fi
  choose_host_header_mode MAIN "$UPSTREAM_HOST" || return 1
}

collect_split_front_media_params() {
  choose_media_path_preset || return 1
  echo "== 前端 / API 上游 =="
  choose_upstream_scheme FRONT_SCHEME "请选择前端/API 上游协议："
  prompt FRONT_HOST "请输入前端/API 上游主机名或IP"
  FRONT_HOST="$(strip_scheme "$FRONT_HOST")"
  [ -n "$FRONT_HOST" ] || { echo "前端/API 上游不能为空"; return 1; }
  prompt FRONT_PORT "请输入前端/API 上游端口" "$([ "$FRONT_SCHEME" = "https" ] && echo 443 || echo 80)"
  is_port "$FRONT_PORT" || { echo "前端/API 上游端口不合法"; return 1; }
  if [ "$FRONT_SCHEME" = "https" ]; then
    yesno FRONT_SKIP_VERIFY "前端/API 上游证书异常时是否跳过验证" "y"
  else
    FRONT_SKIP_VERIFY="n"
  fi
  choose_host_header_mode FRONT "$FRONT_HOST" || return 1

  echo "== 媒体流上游 =="
  choose_upstream_scheme MEDIA_SCHEME "请选择媒体流上游协议："
  prompt MEDIA_HOST "请输入媒体流上游主机名或IP"
  MEDIA_HOST="$(strip_scheme "$MEDIA_HOST")"
  [ -n "$MEDIA_HOST" ] || { echo "媒体流上游不能为空"; return 1; }
  prompt MEDIA_PORT "请输入媒体流上游端口" "$([ "$MEDIA_SCHEME" = "https" ] && echo 443 || echo 80)"
  is_port "$MEDIA_PORT" || { echo "媒体流上游端口不合法"; return 1; }
  if [ "$MEDIA_SCHEME" = "https" ]; then
    yesno MEDIA_SKIP_VERIFY "媒体流上游证书异常时是否跳过验证" "y"
  else
    MEDIA_SKIP_VERIFY="n"
  fi
  choose_host_header_mode MEDIA "$MEDIA_HOST" || return 1
}

collect_media_only_split_params() {
  choose_media_path_preset || return 1
  echo "== 主上游（默认全部路径） =="
  choose_upstream_scheme MAIN_SCHEME "请选择主上游协议："
  prompt MAIN_HOST "请输入主上游主机名或IP"
  MAIN_HOST="$(strip_scheme "$MAIN_HOST")"
  [ -n "$MAIN_HOST" ] || { echo "主上游不能为空"; return 1; }
  prompt MAIN_PORT "请输入主上游端口" "$([ "$MAIN_SCHEME" = "https" ] && echo 443 || echo 80)"
  is_port "$MAIN_PORT" || { echo "主上游端口不合法"; return 1; }
  if [ "$MAIN_SCHEME" = "https" ]; then
    yesno MAIN_SKIP_VERIFY "主上游证书异常时是否跳过验证" "y"
  else
    MAIN_SKIP_VERIFY="n"
  fi
  choose_host_header_mode MAIN "$MAIN_HOST" || return 1

  echo "== 媒体流专用上游 =="
  choose_upstream_scheme MEDIA_SCHEME "请选择媒体流专用上游协议："
  prompt MEDIA_HOST "请输入媒体流专用上游主机名或IP"
  MEDIA_HOST="$(strip_scheme "$MEDIA_HOST")"
  [ -n "$MEDIA_HOST" ] || { echo "媒体流专用上游不能为空"; return 1; }
  prompt MEDIA_PORT "请输入媒体流专用上游端口" "$([ "$MEDIA_SCHEME" = "https" ] && echo 443 || echo 80)"
  is_port "$MEDIA_PORT" || { echo "媒体流专用上游端口不合法"; return 1; }
  if [ "$MEDIA_SCHEME" = "https" ]; then
    yesno MEDIA_SKIP_VERIFY "媒体流专用上游证书异常时是否跳过验证" "y"
  else
    MEDIA_SKIP_VERIFY="n"
  fi
  choose_host_header_mode MEDIA "$MEDIA_HOST" || return 1
}

site_exists() {
  local domain="$1"
  local port="$2"
  local conf
  conf="$(conf_path_for_site "$domain" "$port")"
  [ -f "$conf" ]
}

site_meta_value() {
  local file="$1"
  local key="$2"
  grep -E "^# META ${key}=" "$file" | head -n1 | sed -E "s/^# META ${key}=//" || true
}

url_scheme_from_meta() {
  echo "$1" | sed -E 's#^([a-zA-Z]+)://.*#\1#'
}

url_host_from_meta() {
  echo "$1" | sed -E 's#^[a-zA-Z]+://([^:/]+).*#\1#'
}

url_port_from_meta() {
  echo "$1" | sed -E 's#^[a-zA-Z]+://[^:/]+:([0-9]+).*$#\1#'
}

collect_site_records() {
  SITE_RECORDS=()
  SITE_RECORD_COUNT=0
  local dir f domain port mode summary
  for dir in "$HTTP_D" "$CONF_D"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/${CONF_PREFIX}*.conf; do
      [ -e "$f" ] || continue
      domain="$(site_meta_value "$f" domain)"
      port="$(site_meta_value "$f" port)"
      mode="$(site_meta_value "$f" mode)"
      summary="$(site_meta_value "$f" summary)"
      SITE_RECORDS+=("$f|$domain|$port|$mode|$summary")
    done
  done
  SITE_RECORD_COUNT="${#SITE_RECORDS[@]}"
}

list_sites() {
  choose_site_conf_dir
  collect_site_records
  echo "=== 已有站点 ==="
  if [ "$SITE_RECORD_COUNT" -eq 0 ]; then
    echo "（空）"
    echo
    return 0
  fi

  local i f domain port mode summary
  for ((i=0; i<SITE_RECORD_COUNT; i++)); do
    IFS='|' read -r f domain port mode summary <<< "${SITE_RECORDS[$i]}"
    echo "$((i+1))) 域名: ${domain:-未知} | 端口: ${port:-未知} | 模式: ${mode:-未知}"
    echo "    上游: ${summary:-未知}"
    echo "    配置: $f"
  done
  echo
}

write_proxy_conf_standard() {
  local domain="$1" listen_port="$2" enable_auth="$3" auth_user="$4" auth_pass="$5"
  local upstream_scheme="$6" upstream_host="$7" upstream_port="$8" skip_verify="$9"
  local host_mode="${10}" host_custom="${11}"
  local conf_path auth_path ssl_verify_block host_header_line common_block summary

  conf_path="$(conf_path_for_site "$domain" "$listen_port")"
  auth_path="$(htpasswd_path_for_site "$domain" "$listen_port")"
  ssl_verify_block="$(proxy_ssl_verify_block "$skip_verify")"
  host_header_line="$(render_host_header_line "$host_mode" "$upstream_host" "$host_custom")"
  common_block="$(render_proxy_common_block "$ssl_verify_block")"
  summary="${upstream_scheme}://${upstream_host}:${upstream_port}"

  [ "$enable_auth" = "y" ] && htpasswd -bc "$auth_path" "$auth_user" "$auth_pass" >/dev/null || rm -f "$auth_path" 2>/dev/null || true

  cat > "$conf_path" <<EOF
# META domain=${domain}
# META port=${listen_port}
# META mode=standard
# META summary=${summary}
# META upstream_main=${summary}
server {
    listen ${listen_port} ssl http2;
    server_name ${domain};

    ssl_certificate     ${CERT_HOME}/${domain}/fullchain.cer;
    ssl_certificate_key ${CERT_HOME}/${domain}/private.key;

$(render_auth_block "$enable_auth" "$auth_path")

    location / {
        proxy_pass ${upstream_scheme}://${upstream_host}:${upstream_port};
        ${host_header_line}
${common_block}
    }
}
EOF
  echo "$conf_path"
}

write_proxy_conf_stream() {
  local domain="$1" listen_port="$2" enable_auth="$3" auth_user="$4" auth_pass="$5"
  local upstream_scheme="$6" upstream_host="$7" upstream_port="$8" skip_verify="$9"
  local host_mode="${10}" host_custom="${11}"
  local conf_path auth_path ssl_verify_block host_header_line common_block stream_extra_block summary

  conf_path="$(conf_path_for_site "$domain" "$listen_port")"
  auth_path="$(htpasswd_path_for_site "$domain" "$listen_port")"
  ssl_verify_block="$(proxy_ssl_verify_block "$skip_verify")"
  host_header_line="$(render_host_header_line "$host_mode" "$upstream_host" "$host_custom")"
  common_block="$(render_proxy_common_block "$ssl_verify_block")"
  stream_extra_block="$(render_proxy_stream_extra_block)"
  summary="${upstream_scheme}://${upstream_host}:${upstream_port}"

  [ "$enable_auth" = "y" ] && htpasswd -bc "$auth_path" "$auth_user" "$auth_pass" >/dev/null || rm -f "$auth_path" 2>/dev/null || true

  cat > "$conf_path" <<EOF
# META domain=${domain}
# META port=${listen_port}
# META mode=stream_http
# META summary=${summary}
# META upstream_main=${summary}
server {
    listen ${listen_port} ssl http2;
    server_name ${domain};

    ssl_certificate     ${CERT_HOME}/${domain}/fullchain.cer;
    ssl_certificate_key ${CERT_HOME}/${domain}/private.key;

$(render_auth_block "$enable_auth" "$auth_path")

    location / {
        proxy_pass ${upstream_scheme}://${upstream_host}:${upstream_port};
        ${host_header_line}
${common_block}
${stream_extra_block}
    }
}
EOF
  echo "$conf_path"
}

write_proxy_conf_split_front_media() {
  local domain="$1" listen_port="$2" enable_auth="$3" auth_user="$4" auth_pass="$5"
  local front_scheme="$6" front_host="$7" front_port="$8" front_skip_verify="$9" front_host_mode="${10}" front_host_custom="${11}"
  local media_scheme="${12}" media_host="${13}" media_port="${14}" media_skip_verify="${15}" media_host_mode="${16}" media_host_custom="${17}"
  local conf_path auth_path front_verify media_verify front_host_line media_host_line front_common media_common summary

  conf_path="$(conf_path_for_site "$domain" "$listen_port")"
  auth_path="$(htpasswd_path_for_site "$domain" "$listen_port")"
  front_verify="$(proxy_ssl_verify_block "$front_skip_verify")"
  media_verify="$(proxy_ssl_verify_block "$media_skip_verify")"
  front_host_line="$(render_host_header_line "$front_host_mode" "$front_host" "$front_host_custom")"
  media_host_line="$(render_host_header_line "$media_host_mode" "$media_host" "$media_host_custom")"
  front_common="$(render_proxy_common_block "$front_verify")"
  media_common="$(render_proxy_common_block "$media_verify")"
  summary="front=${front_scheme}://${front_host}:${front_port} ; media=${media_scheme}://${media_host}:${media_port}"

  [ "$enable_auth" = "y" ] && htpasswd -bc "$auth_path" "$auth_user" "$auth_pass" >/dev/null || rm -f "$auth_path" 2>/dev/null || true

  cat > "$conf_path" <<EOF
# META domain=${domain}
# META port=${listen_port}
# META mode=split_front_media
# META media_path_preset=${MEDIA_PATH_PRESET:-emby}
# META media_path_regex=${MEDIA_PATH_REGEX}
# META summary=${summary}
# META upstream_front=${front_scheme}://${front_host}:${front_port}
# META upstream_media=${media_scheme}://${media_host}:${media_port}
server {
    listen ${listen_port} ssl http2;
    server_name ${domain};

    ssl_certificate     ${CERT_HOME}/${domain}/fullchain.cer;
    ssl_certificate_key ${CERT_HOME}/${domain}/private.key;

$(render_auth_block "$enable_auth" "$auth_path")

    location ~* ${MEDIA_PATH_REGEX} {
        proxy_pass ${media_scheme}://${media_host}:${media_port};
        ${media_host_line}
${media_common}
    }

    location / {
        proxy_pass ${front_scheme}://${front_host}:${front_port};
        ${front_host_line}
${front_common}
    }
}
EOF
  echo "$conf_path"
}

write_proxy_conf_media_only_split() {
  local domain="$1" listen_port="$2" enable_auth="$3" auth_user="$4" auth_pass="$5"
  local main_scheme="$6" main_host="$7" main_port="$8" main_skip_verify="$9" main_host_mode="${10}" main_host_custom="${11}"
  local media_scheme="${12}" media_host="${13}" media_port="${14}" media_skip_verify="${15}" media_host_mode="${16}" media_host_custom="${17}"
  local conf_path auth_path main_verify media_verify main_host_line media_host_line main_common media_common summary

  conf_path="$(conf_path_for_site "$domain" "$listen_port")"
  auth_path="$(htpasswd_path_for_site "$domain" "$listen_port")"
  main_verify="$(proxy_ssl_verify_block "$main_skip_verify")"
  media_verify="$(proxy_ssl_verify_block "$media_skip_verify")"
  main_host_line="$(render_host_header_line "$main_host_mode" "$main_host" "$main_host_custom")"
  media_host_line="$(render_host_header_line "$media_host_mode" "$media_host" "$media_host_custom")"
  main_common="$(render_proxy_common_block "$main_verify")"
  media_common="$(render_proxy_common_block "$media_verify")"
  summary="main=${main_scheme}://${main_host}:${main_port} ; media=${media_scheme}://${media_host}:${media_port}"

  [ "$enable_auth" = "y" ] && htpasswd -bc "$auth_path" "$auth_user" "$auth_pass" >/dev/null || rm -f "$auth_path" 2>/dev/null || true

  cat > "$conf_path" <<EOF
# META domain=${domain}
# META port=${listen_port}
# META mode=media_only_split
# META media_path_preset=${MEDIA_PATH_PRESET:-emby}
# META media_path_regex=${MEDIA_PATH_REGEX}
# META summary=${summary}
# META upstream_main=${main_scheme}://${main_host}:${main_port}
# META upstream_media=${media_scheme}://${media_host}:${media_port}
server {
    listen ${listen_port} ssl http2;
    server_name ${domain};

    ssl_certificate     ${CERT_HOME}/${domain}/fullchain.cer;
    ssl_certificate_key ${CERT_HOME}/${domain}/private.key;

$(render_auth_block "$enable_auth" "$auth_path")

    location ~* ${MEDIA_PATH_REGEX} {
        proxy_pass ${media_scheme}://${media_host}:${media_port};
        ${media_host_line}
${media_common}
    }

    location / {
        proxy_pass ${main_scheme}://${main_host}:${main_port};
        ${main_host_line}
${main_common}
    }
}
EOF
  echo "$conf_path"
}

write_proxy_conf_by_mode() {
  case "$PROXY_MODE" in
    standard)
      write_proxy_conf_standard "$DOMAIN" "$LISTEN_PORT" "$ENABLE_AUTH" "$AUTH_USER" "$AUTH_PASS" \
        "$UPSTREAM_SCHEME" "$UPSTREAM_HOST" "$UPSTREAM_PORT" "$SKIP_VERIFY" "$MAIN_HOST_MODE" "$MAIN_HOST_CUSTOM"
      ;;
    stream_http)
      write_proxy_conf_stream "$DOMAIN" "$LISTEN_PORT" "$ENABLE_AUTH" "$AUTH_USER" "$AUTH_PASS" \
        "$UPSTREAM_SCHEME" "$UPSTREAM_HOST" "$UPSTREAM_PORT" "$SKIP_VERIFY" "$MAIN_HOST_MODE" "$MAIN_HOST_CUSTOM"
      ;;
    split_front_media)
      write_proxy_conf_split_front_media "$DOMAIN" "$LISTEN_PORT" "$ENABLE_AUTH" "$AUTH_USER" "$AUTH_PASS" \
        "$FRONT_SCHEME" "$FRONT_HOST" "$FRONT_PORT" "$FRONT_SKIP_VERIFY" "$FRONT_HOST_MODE" "$FRONT_HOST_CUSTOM" \
        "$MEDIA_SCHEME" "$MEDIA_HOST" "$MEDIA_PORT" "$MEDIA_SKIP_VERIFY" "$MEDIA_HOST_MODE" "$MEDIA_HOST_CUSTOM"
      ;;
    media_only_split)
      write_proxy_conf_media_only_split "$DOMAIN" "$LISTEN_PORT" "$ENABLE_AUTH" "$AUTH_USER" "$AUTH_PASS" \
        "$MAIN_SCHEME" "$MAIN_HOST" "$MAIN_PORT" "$MAIN_SKIP_VERIFY" "$MAIN_HOST_MODE" "$MAIN_HOST_CUSTOM" \
        "$MEDIA_SCHEME" "$MEDIA_HOST" "$MEDIA_PORT" "$MEDIA_SKIP_VERIFY" "$MEDIA_HOST_MODE" "$MEDIA_HOST_CUSTOM"
      ;;
    *)
      echo "未知模式: $PROXY_MODE"
      return 1
      ;;
  esac
}

test_nginx() {
  echo "==> 检查 nginx 配置..."
  nginx -t
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

  choose_proxy_mode || return 1
  collect_common_site_params || return 1

  case "$PROXY_MODE" in
    standard|stream_http) collect_standard_params || return 1 ;;
    split_front_media) collect_split_front_media_params || return 1 ;;
    media_only_split) collect_media_only_split_params || return 1 ;;
  esac

  issue_cert "$DOMAIN" "$DNS_PROVIDER"
  install_cert "$DOMAIN"
  conf_path="$(write_proxy_conf_by_mode)"

  echo "==> 已写入配置: $conf_path"
  test_nginx
  enable_start_nginx
  reload_nginx

  echo "==> 当前监听端口："
  ss -lntp | grep -E ":${LISTEN_PORT}\\b" || true

  echo
  echo "新增完成，访问地址："
  echo "https://${DOMAIN}:${LISTEN_PORT}"
  echo
}

show_site_detail() {
  need_root
  choose_site_conf_dir
  list_sites
  collect_site_records
  [ "$SITE_RECORD_COUNT" -gt 0 ] || { echo "当前没有站点"; return 0; }

  while true; do
    read -r -p "请输入要查看详情的站点编号: " SITE_INDEX </dev/tty || true
    case "$SITE_INDEX" in
      ''|*[!0-9]*) echo "请输入数字编号" ;;
      *)
        if [ "$SITE_INDEX" -ge 1 ] && [ "$SITE_INDEX" -le "$SITE_RECORD_COUNT" ]; then
          break
        fi
        echo "编号超出范围"
        ;;
    esac
  done

  local record conf domain port mode summary media_path_preset media_path_regex upstream_main upstream_front upstream_media
  record="${SITE_RECORDS[$((SITE_INDEX-1))]}"
  IFS='|' read -r conf domain port mode summary <<< "$record"
  media_path_preset="$(site_meta_value "$conf" media_path_preset)"
  media_path_regex="$(site_meta_value "$conf" media_path_regex)"
  upstream_main="$(site_meta_value "$conf" upstream_main)"
  upstream_front="$(site_meta_value "$conf" upstream_front)"
  upstream_media="$(site_meta_value "$conf" upstream_media)"

  echo
  echo "=========== 站点详情 ==========="
  echo "域名: ${domain:-未知}"
  echo "端口: ${port:-未知}"
  echo "模式: ${mode:-未知}"
  echo "配置文件: $conf"
  echo "证书目录: ${CERT_HOME}/${domain}"
  echo "站点摘要: ${summary:-未知}"
  [ -n "$upstream_main" ] && echo "主上游: $upstream_main"
  [ -n "$upstream_front" ] && echo "前端/API 上游: $upstream_front"
  [ -n "$upstream_media" ] && echo "媒体流上游: $upstream_media"
  [ -n "$media_path_preset" ] && echo "媒体路径预设: $media_path_preset"
  [ -n "$media_path_regex" ] && echo "媒体路径正则: $media_path_regex"
  if grep -q 'auth_basic ' "$conf" 2>/dev/null; then
    echo "BasicAuth: 已启用"
  else
    echo "BasicAuth: 未启用"
  fi
  echo "================================"
  echo
}

reissue_site_cert() {
  need_root
  ensure_deps
  ensure_dirs

  if [ ! -x "${ACME_HOME}/acme.sh" ]; then
    echo "未检测到 acme.sh，请先执行「初始化系统环境」"
    return 1
  fi

  list_sites
  collect_site_records
  [ "$SITE_RECORD_COUNT" -gt 0 ] || { echo "当前没有站点"; return 0; }

  while true; do
    read -r -p "请输入要重新签发证书的站点编号: " SITE_INDEX </dev/tty || true
    case "$SITE_INDEX" in
      ''|*[!0-9]*) echo "请输入数字编号" ;;
      *)
        if [ "$SITE_INDEX" -ge 1 ] && [ "$SITE_INDEX" -le "$SITE_RECORD_COUNT" ]; then
          break
        fi
        echo "编号超出范围"
        ;;
    esac
  done

  local record conf domain port
  record="${SITE_RECORDS[$((SITE_INDEX-1))]}"
  IFS='|' read -r conf domain port _mode _summary <<< "$record"

  echo "将重新为 ${domain} 申请/安装证书。"
  choose_dns_provider || return 1
  setup_dns_env "$DNS_PROVIDER"

  issue_cert "$domain" "$DNS_PROVIDER"
  install_cert "$domain"
  test_nginx
  reload_nginx
  echo "==> 证书已重新签发并安装"
  echo "==> 自动续签仍由 acme.sh 默认机制负责，reloadcmd 保持启用"
  echo
}

edit_site() {
  need_root
  ensure_deps
  ensure_dirs

  list_sites
  collect_site_records
  [ "$SITE_RECORD_COUNT" -gt 0 ] || { echo "当前没有站点"; return 0; }

  while true; do
    read -r -p "请输入要编辑的站点编号: " SITE_INDEX </dev/tty || true
    case "$SITE_INDEX" in
      ''|*[!0-9]*) echo "请输入数字编号" ;;
      *)
        if [ "$SITE_INDEX" -ge 1 ] && [ "$SITE_INDEX" -le "$SITE_RECORD_COUNT" ]; then
          break
        fi
        echo "编号超出范围"
        ;;
    esac
  done

  local record conf old_domain old_port old_mode old_summary
  record="${SITE_RECORDS[$((SITE_INDEX-1))]}"
  IFS='|' read -r conf old_domain old_port old_mode old_summary <<< "$record"

  DOMAIN="$old_domain"
  LISTEN_PORT="$old_port"
  PROXY_MODE="$old_mode"

  echo "当前站点: ${old_domain}:${old_port}"
  echo "当前模式: ${old_mode}"
  yesno CHANGE_MODE "是否修改反代模式" "n"
  if [ "$CHANGE_MODE" = "y" ]; then
    choose_proxy_mode || return 1
  fi

  yesno CHANGE_PORT "是否修改监听端口" "n"
  if [ "$CHANGE_PORT" = "y" ]; then
    prompt LISTEN_PORT "请输入新的 HTTPS 监听端口" "$old_port"
    is_port "$LISTEN_PORT" || { echo "端口不合法"; return 1; }
  fi

  yesno CHANGE_AUTH "是否重新设置 BasicAuth" "n"
  ENABLE_AUTH="n"
  AUTH_USER="emby"
  AUTH_PASS=""
  if grep -q 'auth_basic ' "$conf" 2>/dev/null; then
    ENABLE_AUTH="y"
  fi
  if [ "$CHANGE_AUTH" = "y" ]; then
    yesno ENABLE_AUTH "是否启用 BasicAuth 额外门禁" "$ENABLE_AUTH"
    if [ "$ENABLE_AUTH" = "y" ]; then
      prompt AUTH_USER "BasicAuth 用户名" "emby"
      prompt AUTH_PASS "BasicAuth 密码（留空表示保持旧密码，不推荐）"
      [ -n "$AUTH_PASS" ] || { echo "密码不能为空"; return 1; }
    fi
  else
    if [ "$ENABLE_AUTH" = "y" ]; then
      AUTH_USER="emby"
      AUTH_PASS="temp-pass-change-required"
    fi
  fi

  case "$PROXY_MODE" in
    standard|stream_http)
      old_upstream_main="$(site_meta_value "$conf" upstream_main)"
      UPSTREAM_SCHEME="$(url_scheme_from_meta "$old_upstream_main")"
      UPSTREAM_HOST="$(url_host_from_meta "$old_upstream_main")"
      UPSTREAM_PORT="$(url_port_from_meta "$old_upstream_main")"
      SKIP_VERIFY="$(grep -q 'proxy_ssl_verify off;' "$conf" && echo y || echo n)"
      MAIN_HOST_MODE="upstream"
      MAIN_HOST_CUSTOM=""
      echo "== 编辑标准/流式传输优化模式上游 =="
      choose_upstream_scheme UPSTREAM_SCHEME "请选择上游协议（当前 ${UPSTREAM_SCHEME:-https}）：" || return 1
      prompt UPSTREAM_HOST "请输入上游主机名或IP" "$UPSTREAM_HOST"
      UPSTREAM_HOST="$(strip_scheme "$UPSTREAM_HOST")"
      prompt UPSTREAM_PORT "请输入上游端口" "$UPSTREAM_PORT"
      is_port "$UPSTREAM_PORT" || { echo "上游端口不合法"; return 1; }
      if [ "$UPSTREAM_SCHEME" = "https" ]; then
        yesno SKIP_VERIFY "如上游 HTTPS 证书异常/自签，是否跳过验证" "$SKIP_VERIFY"
      else
        SKIP_VERIFY="n"
      fi
      choose_host_header_mode MAIN "$UPSTREAM_HOST" || return 1
      ;;
    split_front_media)
      FRONT_META="$(site_meta_value "$conf" upstream_front)"
      MEDIA_META="$(site_meta_value "$conf" upstream_media)"
      FRONT_SCHEME="$(url_scheme_from_meta "$FRONT_META")"
      FRONT_HOST="$(url_host_from_meta "$FRONT_META")"
      FRONT_PORT="$(url_port_from_meta "$FRONT_META")"
      MEDIA_SCHEME="$(url_scheme_from_meta "$MEDIA_META")"
      MEDIA_HOST="$(url_host_from_meta "$MEDIA_META")"
      MEDIA_PORT="$(url_port_from_meta "$MEDIA_META")"
      FRONT_SKIP_VERIFY="$(grep -q 'proxy_ssl_verify off;' "$conf" && echo y || echo n)"
      MEDIA_SKIP_VERIFY="$FRONT_SKIP_VERIFY"
      choose_media_path_preset || return 1
      echo "== 编辑前端 / API 上游 =="
      choose_upstream_scheme FRONT_SCHEME "请选择前端/API 上游协议（当前 ${FRONT_SCHEME:-https}）：" || return 1
      prompt FRONT_HOST "请输入前端/API 上游主机名或IP" "$FRONT_HOST"
      FRONT_HOST="$(strip_scheme "$FRONT_HOST")"
      prompt FRONT_PORT "请输入前端/API 上游端口" "$FRONT_PORT"
      is_port "$FRONT_PORT" || { echo "前端/API 上游端口不合法"; return 1; }
      if [ "$FRONT_SCHEME" = "https" ]; then
        yesno FRONT_SKIP_VERIFY "前端/API 上游证书异常时是否跳过验证" "$FRONT_SKIP_VERIFY"
      else
        FRONT_SKIP_VERIFY="n"
      fi
      choose_host_header_mode FRONT "$FRONT_HOST" || return 1
      echo "== 编辑媒体流上游 =="
      choose_upstream_scheme MEDIA_SCHEME "请选择媒体流上游协议（当前 ${MEDIA_SCHEME:-https}）：" || return 1
      prompt MEDIA_HOST "请输入媒体流上游主机名或IP" "$MEDIA_HOST"
      MEDIA_HOST="$(strip_scheme "$MEDIA_HOST")"
      prompt MEDIA_PORT "请输入媒体流上游端口" "$MEDIA_PORT"
      is_port "$MEDIA_PORT" || { echo "媒体流上游端口不合法"; return 1; }
      if [ "$MEDIA_SCHEME" = "https" ]; then
        yesno MEDIA_SKIP_VERIFY "媒体流上游证书异常时是否跳过验证" "$MEDIA_SKIP_VERIFY"
      else
        MEDIA_SKIP_VERIFY="n"
      fi
      choose_host_header_mode MEDIA "$MEDIA_HOST" || return 1
      ;;
    media_only_split)
      MAIN_META="$(site_meta_value "$conf" upstream_main)"
      MEDIA_META="$(site_meta_value "$conf" upstream_media)"
      MAIN_SCHEME="$(url_scheme_from_meta "$MAIN_META")"
      MAIN_HOST="$(url_host_from_meta "$MAIN_META")"
      MAIN_PORT="$(url_port_from_meta "$MAIN_META")"
      MEDIA_SCHEME="$(url_scheme_from_meta "$MEDIA_META")"
      MEDIA_HOST="$(url_host_from_meta "$MEDIA_META")"
      MEDIA_PORT="$(url_port_from_meta "$MEDIA_META")"
      MAIN_SKIP_VERIFY="$(grep -q 'proxy_ssl_verify off;' "$conf" && echo y || echo n)"
      MEDIA_SKIP_VERIFY="$MAIN_SKIP_VERIFY"
      choose_media_path_preset || return 1
      echo "== 编辑主上游 =="
      choose_upstream_scheme MAIN_SCHEME "请选择主上游协议（当前 ${MAIN_SCHEME:-https}）：" || return 1
      prompt MAIN_HOST "请输入主上游主机名或IP" "$MAIN_HOST"
      MAIN_HOST="$(strip_scheme "$MAIN_HOST")"
      prompt MAIN_PORT "请输入主上游端口" "$MAIN_PORT"
      is_port "$MAIN_PORT" || { echo "主上游端口不合法"; return 1; }
      if [ "$MAIN_SCHEME" = "https" ]; then
        yesno MAIN_SKIP_VERIFY "主上游证书异常时是否跳过验证" "$MAIN_SKIP_VERIFY"
      else
        MAIN_SKIP_VERIFY="n"
      fi
      choose_host_header_mode MAIN "$MAIN_HOST" || return 1
      echo "== 编辑媒体流专用上游 =="
      choose_upstream_scheme MEDIA_SCHEME "请选择媒体流专用上游协议（当前 ${MEDIA_SCHEME:-https}）：" || return 1
      prompt MEDIA_HOST "请输入媒体流专用上游主机名或IP" "$MEDIA_HOST"
      MEDIA_HOST="$(strip_scheme "$MEDIA_HOST")"
      prompt MEDIA_PORT "请输入媒体流专用上游端口" "$MEDIA_PORT"
      is_port "$MEDIA_PORT" || { echo "媒体流专用上游端口不合法"; return 1; }
      if [ "$MEDIA_SCHEME" = "https" ]; then
        yesno MEDIA_SKIP_VERIFY "媒体流专用上游证书异常时是否跳过验证" "$MEDIA_SKIP_VERIFY"
      else
        MEDIA_SKIP_VERIFY="n"
      fi
      choose_host_header_mode MEDIA "$MEDIA_HOST" || return 1
      ;;
    *)
      echo "不支持的模式: $PROXY_MODE"
      return 1
      ;;
  esac

  old_auth_path="$(htpasswd_path_for_site "$old_domain" "$old_port")"
  if [ "$CHANGE_AUTH" = "n" ] && [ -f "$old_auth_path" ]; then
    cp -f "$old_auth_path" "${old_auth_path}.bak.edit" 2>/dev/null || true
  fi

  new_conf="$(write_proxy_conf_by_mode)"
  new_auth_path="$(htpasswd_path_for_site "$DOMAIN" "$LISTEN_PORT")"
  if [ "$CHANGE_AUTH" = "n" ] && [ -f "$old_auth_path" ]; then
    mv -f "$old_auth_path" "$new_auth_path" 2>/dev/null || cp -f "$old_auth_path" "$new_auth_path" 2>/dev/null || true
  fi
  if [ "$old_domain" != "$DOMAIN" ] || [ "$old_port" != "$LISTEN_PORT" ]; then
    rm -f "$(conf_path_for_site "$old_domain" "$old_port")" 2>/dev/null || true
    [ "$old_auth_path" != "$new_auth_path" ] && rm -f "$old_auth_path" 2>/dev/null || true
  fi

  test_nginx
  reload_nginx
  echo "==> 站点已更新: $new_conf"
  echo
}

remove_site() {
  need_root
  choose_site_conf_dir

  list_sites
  collect_site_records
  [ "$SITE_RECORD_COUNT" -gt 0 ] || { echo "当前没有可删除站点"; return 0; }

  while true; do
    read -r -p "请输入要删除的站点编号: " SITE_INDEX </dev/tty || true
    case "$SITE_INDEX" in
      ''|*[!0-9]*) echo "请输入数字编号" ;;
      *)
        if [ "$SITE_INDEX" -ge 1 ] && [ "$SITE_INDEX" -le "$SITE_RECORD_COUNT" ]; then
          break
        fi
        echo "编号超出范围"
        ;;
    esac
  done

  local record conf domain port auth_path same_domain_left=0 i rec f d p m s
  record="${SITE_RECORDS[$((SITE_INDEX-1))]}"
  IFS='|' read -r conf domain port _mode _summary <<< "$record"
  auth_path="$(htpasswd_path_for_site "$domain" "$port")"

  yesno CONFIRM_REMOVE "确认删除站点 ${domain}:${port}" "n"
  [ "$CONFIRM_REMOVE" = "y" ] || { echo "已取消"; return 0; }

  rm -f "$conf"
  rm -f "$auth_path" 2>/dev/null || true

  collect_site_records
  for ((i=0; i<SITE_RECORD_COUNT; i++)); do
    rec="${SITE_RECORDS[$i]}"
    IFS='|' read -r f d p m s <<< "$rec"
    if [ "$d" = "$domain" ]; then
      same_domain_left=1
      break
    fi
  done

  if [ "$same_domain_left" -eq 0 ]; then
    rm -rf "${CERT_HOME}/${domain}"
    if [ -x "${ACME_HOME}/acme.sh" ]; then
      "${ACME_HOME}/acme.sh" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
    fi
    echo "==> 已删除该站点对应证书目录，并移除 acme 续签记录: ${domain}"
  else
    echo "==> 检测到同域名还有其他站点在使用，已保留证书: ${domain}"
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
  rm -f "${CONF_D}/${CONF_PREFIX}"*.conf 2>/dev/null || true
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
    service_stop_nginx
  fi

  yesno REMOVE_NGINX "是否卸载 nginx 软件包（仅当本机不再需要 nginx 时选择 y）" "n"
  if [ "$REMOVE_NGINX" = "y" ]; then
    service_stop_nginx
    if command -v rc-update >/dev/null 2>&1; then
      rc-update del nginx default >/dev/null 2>&1 || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable nginx >/dev/null 2>&1 || true
    fi
    pkg_remove nginx
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
    echo "5) 编辑反代站点"
    echo "6) 查看站点详情"
    echo "7) 重新签发站点证书"
    echo "8) 卸载本项目"
    echo "0) 退出"
    read -r -p "请选择: " CHOICE </dev/tty
    case "$CHOICE" in
      1) init_system ;;
      2) add_site ;;
      3) remove_site ;;
      4) list_sites ;;
      5) edit_site ;;
      6) show_site_detail ;;
      7) reissue_site_cert ;;
      8) uninstall_all ;;
      0) exit 0 ;;
      *) echo "无效选择"; echo ;;
    esac
  done
}

main_menu "$@"
