#!/usr/bin/env bash
# Emby Proxy Alpine Lite - Uninstall Script
# 仅清理本项目生成的配置、证书和 acme.sh 相关内容。
# 默认不会卸载 bash/curl/openssl 等基础组件。
# 如需彻底移除 nginx，可在交互中选择。

set -euo pipefail

HTTP_D="/etc/nginx/http.d"
CONF_PREFIX="emby-lite-"
CERT_HOME="/etc/nginx/certs"
ACME_HOME="/root/.acme.sh"

need_root() {
  [ "$(id -u)" -eq 0 ] || {
    echo "请用 root 运行"
    exit 1
  }
}

yesno() {
  local var_name="$1"
  local text="$2"
  local default="${3:-n}"
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

backup_if_exists() {
  local path="$1"
  if [ -e "$path" ]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "${path}.bak.${ts}" 2>/dev/null || true
  fi
}

remove_project_nginx_confs() {
  echo "==> 删除项目生成的 nginx 配置..."
  rm -f "${HTTP_D}/${CONF_PREFIX}"*.conf 2>/dev/null || true
  rm -f /etc/nginx/.htpasswd-emby-lite-* 2>/dev/null || true
}

remove_project_certs() {
  echo "==> 删除项目证书目录..."
  if [ -d "$CERT_HOME" ]; then
    find "$CERT_HOME" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
  fi
}

remove_acme() {
  echo "==> 删除 acme.sh ..."
  rm -rf "$ACME_HOME"
}

restore_nginx_conf_if_possible() {
  if ls /etc/nginx/nginx.conf.bak.* >/dev/null 2>&1; then
    latest_bak="$(ls -1t /etc/nginx/nginx.conf.bak.* | head -n1)"
    echo "==> 发现 nginx.conf 备份：$latest_bak"
    yesno RESTORE_MAIN "是否恢复最近一次 nginx.conf 备份" "y"
    if [ "$RESTORE_MAIN" = "y" ]; then
      cp -f "$latest_bak" /etc/nginx/nginx.conf
      echo "已恢复 /etc/nginx/nginx.conf"
    fi
  else
    echo "==> 未发现 nginx.conf 备份，跳过恢复"
  fi
}

reload_or_stop_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      rc-service nginx reload >/dev/null 2>&1 || rc-service nginx restart >/dev/null 2>&1 || true
      echo "==> nginx 已重载"
    else
      echo "==> 当前 nginx 配置不完整，尝试停止 nginx"
      rc-service nginx stop >/dev/null 2>&1 || true
    fi
  fi
}

remove_nginx_package_if_needed() {
  yesno REMOVE_NGINX "是否额外卸载 nginx 软件包（仅当此机不再需要 nginx 时选择 y）" "n"
  if [ "$REMOVE_NGINX" = "y" ]; then
    echo "==> 停止并卸载 nginx ..."
    rc-service nginx stop >/dev/null 2>&1 || true
    rc-update del nginx default >/dev/null 2>&1 || true
    apk del nginx >/dev/null 2>&1 || true
  fi
}

main() {
  need_root

  echo "=== Emby Proxy Alpine Lite 卸载脚本 ==="
  echo "将清理："
  echo "- /etc/nginx/http.d/${CONF_PREFIX}*.conf"
  echo "- /etc/nginx/.htpasswd-emby-lite-*"
  echo "- ${CERT_HOME}/ 下本项目签发证书"
  echo "- ${ACME_HOME}"
  echo

  yesno CONFIRM "确认开始卸载" "n"
  [ "$CONFIRM" = "y" ] || { echo "已取消"; exit 0; }

  backup_if_exists /etc/nginx/nginx.conf
  remove_project_nginx_confs
  remove_project_certs
  remove_acme
  restore_nginx_conf_if_possible
  reload_or_stop_nginx
  remove_nginx_package_if_needed

  echo
  echo "========================================"
  echo "卸载完成"
  echo "如你仍有 NAT / 面板 / 安全组端口映射，请记得手动删除。"
  echo "========================================"
}

main "$@"
