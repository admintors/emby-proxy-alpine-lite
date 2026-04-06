# Emby Proxy Alpine Lite

一个适用于 **Alpine Linux 小鸡 / NAT VPS / 非标准端口环境** 的轻量级 Emby 反向代理一键脚本。

主要面向这类场景：

- 服务器配置很低（如 `1C/256M/1G`）
- 没有 `80 / 443 / 8080 / 8443` 端口
- 只能使用其他高位端口
- 需要通过 **DNS 验证** 申请证书
- 上游为 **HTTPS**
- 需要支持 **WebSocket / 长连接**
- 需要在 Alpine 上快速一键部署

---

## 功能特性

- ✅ 适配 **Alpine Linux**
- ✅ 支持 **DNS 验证签发证书**
- ✅ 支持 **非标准 HTTPS 端口**
- ✅ 支持 **HTTPS 上游回源**
- ✅ 支持 **WebSocket / 长连接**
- ✅ 针对 **小内存 / 小磁盘 VPS** 做了轻量化优化
- ✅ 自动生成 Nginx 反代配置
- ✅ 支持 `Cloudflare / 阿里云 DNS / DNSPod`
- ✅ 可选 `BasicAuth` 额外门禁

---

## 适用场景

适合：

- 自用 Emby / Jellyfin 反代
- NAT VPS / 特殊网络环境
- 不能开放 80/443 的机器
- Alpine 小鸡快速部署
- 需要 HTTPS 入口 + HTTPS 上游的场景

不太适合：

- 大规模公网流量入口
- 高并发海量长连接
- 高负载 WebSocket 网关
- 企业级高可用反代集群

---

## 运行环境

- Alpine Linux
- Root 权限
- 已有域名，并且该域名可修改 DNS 记录
- 域名已经解析到当前机器公网 IP
- NAT / 面板 / 安全组已放通你要使用的端口

---

## 支持的 DNS 提供商

当前脚本内置支持：

- Cloudflare
- 阿里云 DNS
- DNSPod

---

## 一键安装


```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/install.sh && bash install.sh
```
---

## 卸载
本项目提供独立卸载脚本，可用于清理以下内容：

- 项目生成的 Nginx 站点配置
- 项目生成的 BasicAuth 文件
- 项目签发并安装到 /etc/nginx/certs/ 的证书
- acme.sh 目录与相关状态

---

## 关于卸载
卸载脚本默认会：

- 删除项目生成的 emby-lite-*.conf
- 删除项目生成的 .htpasswd 文件
- 删除 /etc/nginx/certs/ 下本项目证书
- 删除 /root/.acme.sh
- 尝试恢复最近一次 nginx.conf 备份
- 重载或停止 Nginx

如果你确认这台机器不再需要 Nginx，卸载脚本会额外询问是否删除 nginx 软件包。

---

## 一键卸载


```bash
curl -fsSL -o uninstall.sh https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/uninstall.sh && bash uninstall.sh
```
---

## 免责声明
本项目仅供合法、自用场景下的学习与部署参考。
请勿将其用于任何违法用途、公共开放代理用途或违反服务提供商条款的场景。
因错误配置、端口暴露、CDN 误用、DNS API 泄露等导致的损失，使用者需自行承担风险。

---

## 警告⚠️

本代码基于使用ai进行编写，本项目仅作为兴趣爱好，本人不对任何代码所负责！！

---
