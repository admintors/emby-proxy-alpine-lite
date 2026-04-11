
# Emby Proxy Alpine Lite

一个适用于 **Alpine Linux / NAT VPS / 非标准端口环境** 的轻量级 Emby / Jellyfin 反向代理一键脚本。

本项目主要面向以下场景：

- 机器配置较低，例如 `1C / 256M / 1G`
- 没有 `80 / 443 / 8080 / 8443` 端口
- 只能使用其他高位端口
- 需要通过 **DNS 验证** 申请证书
- 上游是 **HTTPS**
- 需要支持 **WebSocket / 长连接**
- 需要在 Alpine 上快速部署并支持**多站点共存**

---

## 功能特性

- ✅ 适配 **Alpine Linux**
- ✅ 支持 **DNS 验证签发证书**（acme.sh）
- ✅ 支持 **非标准 HTTPS 端口**
- ✅ 支持 **HTTPS 上游回源**
- ✅ 支持 **WebSocket / 长连接**
- ✅ 针对 **小内存 / 小磁盘 VPS** 做轻量化优化
- ✅ 自动生成 Nginx 反代配置
- ✅ 支持 `Cloudflare / 阿里云 DNS / DNSPod`
- ✅ 可选 `BasicAuth` 额外门禁
- ✅ 支持 **多个反代站点同时存在并运行**
- ✅ 提供菜单式管理：
  - 初始化系统环境
  - 新增反代站点
  - 删除反代站点
  - 查看已有站点
  - 卸载本项目

---

## 适用场景

适合：

- 自用 Emby / Jellyfin 反代
- NAT VPS / 特殊网络环境
- 无法开放 80/443 的小鸡
- Alpine 系统快速部署
- 需要 HTTPS 入口 + HTTPS 上游的场景
- 希望一台机器同时托管多个反代配置

不太适合：

- 大规模公网入口
- 高并发海量连接
- 重度 WebSocket 网关
- 企业级高可用集群场景

---

## 运行环境

- Alpine Linux
- Root 权限
- 已有域名，并且可修改 DNS 记录
- 域名已正确解析到当前机器公网 IP
- NAT / 面板 / 安全组已放通你要使用的端口

---

## 支持的 DNS 提供商

当前脚本内置支持：

- Cloudflare
- 阿里云 DNS
- DNSPod

---

## 安装方式

> **注意：本脚本是交互式脚本，不建议直接使用 `curl | bash`。**  
> 推荐先下载到本地文件，再执行。

### 推荐安装命令

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/install.sh && bash install.sh
```

或：

```bash
wget -O install.sh https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/install.sh && bash install.sh
```

---

## 使用方式

脚本启动后会显示菜单：

```text
1) 初始化系统环境
2) 新增反代站点
3) 删除反代站点
4) 查看已有站点
5) 卸载本项目
0) 退出
```

---

## 推荐使用顺序

### 第一次部署

先执行脚本，然后按顺序操作：

1. 选择 **1) 初始化系统环境**
2. 再选择 **2) 新增反代站点**

### 以后新增更多站点

只需要再次运行脚本，并选择：

```text
2) 新增反代站点
```

即可新增新的域名 / 端口 / 上游配置，不会影响已有站点。

---

## 菜单功能说明

### 1）初始化系统环境

该选项用于首次部署时执行，主要会：

- 安装依赖软件
- 安装并初始化 `acme.sh`
- 注册 ACME 账户
- 写入轻量化 `nginx.conf`
- 启动并重载 nginx

> 该操作通常只需要执行一次。

---

### 2）新增反代站点

该选项用于新增一个独立站点，主要会：

- 输入入口域名
- 输入 HTTPS 监听端口
- 输入 HTTPS 上游域名 / IP
- 输入上游端口
- 选择 DNS 提供商
- 输入 DNS API 信息
- 可选启用 `BasicAuth`
- 为该域名申请证书
- 生成独立的 Nginx 配置
- 重载 Nginx

每个站点都会生成：

- 独立配置文件
- 独立证书目录
- 独立反代入口

因此支持多站点共存。

---

### 3）删除反代站点

用于删除单个站点：

- 删除指定站点的 Nginx 配置
- 删除对应的 BasicAuth 文件
- 可选删除该域名证书目录
- 重载 Nginx

---

### 4）查看已有站点

列出当前所有由本项目生成的站点信息，包括：

- 域名
- 端口
- 上游
- 配置文件路径

---

### 5）卸载本项目

用于清理本项目生成的所有内容，包括：

- 所有 `emby-lite-*.conf`
- 所有项目生成的 `.htpasswd`
- 项目生成的证书目录
- `acme.sh`
- 可选恢复最近一次 `nginx.conf` 备份
- 可选卸载 `nginx`

---

## 多站点共存说明

本项目支持多个站点同时存在并运行。

例如可以同时配置：

```text
https://a.example.com:2053   -> 上游 A
https://b.example.com:52443  -> 上游 B
https://c.example.com:30443  -> 上游 C
```

每个站点都会生成独立配置文件，例如：

```text
/etc/nginx/http.d/emby-lite-a.example.com-2053.conf
/etc/nginx/http.d/emby-lite-b.example.com-52443.conf
```

每个域名也会拥有独立证书目录，例如：

```text
/etc/nginx/certs/a.example.com/
/etc/nginx/certs/b.example.com/
```

---

## 安装时需要填写的内容

在“初始化系统环境”阶段，通常会填写：

- 用于申请证书的合法邮箱

在“新增反代站点”阶段，通常会填写：

- 入口域名
- 本机 HTTPS 监听端口
- 上游 HTTPS 域名 / IP
- 上游 HTTPS 端口
- DNS 提供商及对应 API 信息
- 是否启用 BasicAuth
- 是否跳过上游 HTTPS 证书校验

---

## 客户端使用方式

部署完成后，客户端填写地址格式如下：

```text
https://你的域名:端口
```

例如：

```text
https://emby.example.com:2053
```

---

## 部署完成后建议检查

### 1. 检查 Nginx 配置

```bash
nginx -t
```

### 2. 检查服务状态

```bash
rc-service nginx status
```

### 3. 检查监听端口

```bash
ss -lntp | grep 你的端口
```

### 4. 检查本机 HTTPS

```bash
openssl s_client -connect 127.0.0.1:你的端口 -servername 你的域名 </dev/null
```

### 5. 检查本机请求

```bash
curl -kv https://127.0.0.1:你的端口/ -H 'Host: 你的域名' --insecure
```

---

## 卸载方式

如果你不想通过菜单卸载，也可以单独执行仓库中的卸载脚本。

### 卸载命令

```bash
curl -fsSL -o uninstall.sh https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/uninstall.sh && bash uninstall.sh
```

或：

```bash
wget -O uninstall.sh https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/uninstall.sh && bash uninstall.sh
```

### 卸载脚本默认会清理

- 项目生成的 `emby-lite-*.conf`
- 项目生成的 `.htpasswd`
- `/etc/nginx/certs/` 下本项目证书
- `/root/.acme.sh`
- 尝试恢复最近一次 `nginx.conf` 备份
- 重载或停止 Nginx

卸载脚本**默认不会**删除以下基础组件：

- bash
- curl
- openssl
- ca-certificates
- socat
- apache2-utils
- iproute2

如果确认该机器不再需要 Nginx，卸载脚本会额外询问是否卸载 `nginx` 软件包。

---

## 常见问题

### 1）客户端报错：`Unable to parse TLS packet header`

通常表示：

- 客户端用 `https://` 连到了一个 **HTTP 端口**
- 或公网端口映射错了
- 或 CDN / 代理层不支持当前 HTTPS 端口

请重点检查：

- Nginx 是否 `listen xxx ssl;`
- 客户端填写的端口是否正确
- NAT 是否把公网端口映射到正确的本机端口
- Cloudflare 是否支持该 HTTPS 端口

---

### 2）脚本提示：`邮箱格式不合法`

如果你是用下面这种方式执行：

```bash
curl ... | bash
```

可能会导致交互输入读取失败。

请改用：

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/install.sh && bash install.sh
```

并确保输入的是合法邮箱，例如：

```text
admin@example.com
```

不要使用：

```text
admin@local
```

---

### 3）证书申请失败

请检查：

- 域名是否已正确解析到服务器公网 IP
- DNS API Token / Key 是否正确
- DNS API 是否有对应域名的修改权限
- 域名记录是否已生效

---

### 4）部署后本机通，公网不通

通常需要检查：

- NAT 映射是否正确
- 面板防火墙 / 安全组是否放行
- 运营商或平台是否拦截该端口
- 是否误用了 CDN 不支持的高位端口

---

### 5）根路径 `/` 返回 404

这不一定代表反代失败。

有些 Emby / Jellyfin / 前置站点：

- 根路径本身返回 404
- 但实际客户端 API、WebSocket、播放路径是正常的

请结合客户端实际连接情况综合判断。

---

### 6）多个站点能否同时运行？

可以。

本项目支持多个站点共存，每个站点：

- 使用独立配置文件
- 使用独立证书目录
- 可以指向不同上游
- 可以使用不同端口

只要你的 NAT / 安全组 / DNS 配置正确，它们可以同时运行。

---

## 安全建议

- 建议仅用于 **自用反代**
- 不建议暴露成公共代理
- 如有需要，可启用 `BasicAuth`
- 如非必须，不建议长期关闭上游证书校验
- 定期检查证书续期和端口暴露情况
- 不要泄露 DNS API Token / Key

---

## 项目定位

这是一个偏实用主义的轻量脚本，重点是：

- Alpine 可用
- 小鸡可跑
- 非标准端口可用
- 配置尽量简单
- 尽可能少踩坑
- 支持菜单式管理和多站点共存

它不是一个重量级面板，也不是完整的反代管理系统。

---

## 免责声明

本项目仅供合法、自用场景下的学习与部署参考。

请勿将其用于任何违法用途、公共开放代理用途或违反服务提供商条款的场景。  
因错误配置、端口暴露、CDN 误用、DNS API 泄露等导致的损失，使用者需自行承担风险。

---

## 警告⚠️

本项目为本人依赖AI进行修改编写的代码，可能存在不当之处，请谨慎使用！
