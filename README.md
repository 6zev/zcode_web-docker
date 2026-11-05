# zcode-web-docker

官方 ZCode Web(上游 [`zai-org/ZCode`](https://github.com/zai-org/ZCode),v3.17.2)的**单镜像 Docker 部署**:
一个容器里跑 Web UI + `@zcode/server`(HTTP/WS)+ Agent CLI `zcode.cjs`(stdio 拉起),单进程单端口。

镜像已由 GitHub Actions 构建并推送到 GHCR:

> 推荐用仓库里的 compose:它会额外起一个**网关容器**(Caddy 反代 + Basic Auth),zcode 本体不再对外发布端口。

```bash
cp .env.example .env      # 至少改掉 GATEWAY_AUTH_PASSWORD
docker compose up -d --build
# 访问 http://<服务器IP>:8080/ : 先过网关口令,再做 Z.ai OAuth 登录
```

只想直连镜像(不经网关,需自行保证不暴露):

```bash
docker pull ghcr.io/6zev/zcode_web_docker:latest
docker run -d --name zcode-web -p 127.0.0.1:3030:3030 \
  -v zcode-data:/root/zcode/data \
  -v /你的/代码目录:/root/zcode/workspace \
  ghcr.io/6zev/zcode_web_docker:latest
```

凭据落在 `/root/zcode/data` 卷,重建容器不掉登录。

> 完整文档见 [DETAILED-README.md](DETAILED-README.md):构建细节、环境变量、验证方法、常见问题。

## 目录结构

| 文件 | 作用 |
|---|---|
| [Dockerfile](Dockerfile) | 两阶段:`builder`(克隆官方仓库 + 构建 server/web/agent)→ `runtime`(非 root、tini、HEALTHCHECK) |
| [docker-compose.yml](docker-compose.yml) | 一条命令起服务:gateway(对外入口)+ zcode-web(内部) |
| [gateway/nginx.conf](gateway/nginx.conf) | **默认网关**:nginx 配置(Basic Auth + 反代 + WebSocket + 限速) |
| [gateway/Caddyfile](gateway/Caddyfile) | 备用网关:同功能的 Caddy 实现(自动 HTTPS,`--profile caddy`) |
| [docker-entrypoint.sh](docker-entrypoint.sh) | 准备数据目录、首次铺默认设置、打印启动诊断 |
| [zcode-preflight.sh](zcode-preflight.sh) | 镜像自检:产物 / 权限 / 网络 / 健康 |
| [.github/workflows/build-image.yml](.github/workflows/build-image.yml) | CI:hadolint/Caddyfile 门禁 + 构建推送 GHCR + 网关端到端冒烟测试 |
| [zcode-web.docker.json](zcode-web.docker.json) | 构建清单:版本、产物路径、运行期环境变量 |
| [DETAILED-README.md](DETAILED-README.md) | 完整文档:构建步骤、变量表、故障排查、实测记录 |
| [VERIFY-NOTES.md](VERIFY-NOTES.md) | 逐条源码核对记录(每条带 `file:line`) |

## CI 工作流

- **触发**:推 `main` / PR(只构建不推送)/ 每周一 03:17 UTC 定时重建 / 手动触发(可选多平台)。
- **lint job**:hadolint(只卡 error)+ shell 语法 + compose/manifest 校验。
- **build job**:Buildx 构建 → 推送 `ghcr.io/6zev/zcode_web_docker`(`latest` / `sha-<短SHA>` / `3.17.2`)
  → 单平台且不推送时,额外 `load` 到本地跑**冒烟测试**(起容器 → 探活 `/api/server-info` 与首页 → 容器内自检脚本)。
- 构建缓存用 `type=gha`,重复构建会快很多。

手动触发多平台构建:

```bash
gh workflow run build-image -f platforms=linux/amd64,linux/arm64 -f push_image=true
```

## 环境要求

- 容器需能访问 `zcode.z.ai`、`api.z.ai`、`open.bigmodel.cn`(登录与推理);不通时给容器配 `HTTPS_PROXY`。
- 只用 Docker 跑镜像:**不需要**本地 Node/pnpm。要自己构建镜像:构建机需能出网,首次构建约 10–25 分钟。
- 卷 `/root/zcode/data` 必须持久化(HOME:凭据、会话库、插件缓存);`/root/zcode/workspace` 是 ZCode 的默认工作目录。
- 镜像默认以 **root** 运行,入口脚本会自动把 `/root/zcode/data` 与 `/root/zcode/workspace` 的属主修正为当前 UID,所以 bind mount 到新建的空目录也不会 `EACCES`。想跑非 root:`--user 1000:1000` + `sudo chown -R 1000:1000 <挂载目录>`。

## 访问保护(网关)

```
浏览器 ──Basic Auth──▶ gateway(nginx:1.27-alpine,对外 8080) ──▶ zcode-web:3030(不发布端口)
```

- 所有请求(含 WebSocket `/ws`)都必须先过 Basic Auth;未认证 401,不会碰到 zcode。
- 改口令:改 `.env` 的 `GATEWAY_AUTH_PASSWORD` 再 `docker compose up -d gateway`(口令在容器启动时算成 apr1 哈希);也可以直接给 `GATEWAY_AUTH_HASH`。
- 限速:`GATEWAY_RATE`(默认 20r/s)+ `GATEWAY_BURST`(默认 200)。**burst 给小了浏览器首屏会 503**,调大即可。
- 上游用变量 + Docker 内嵌 DNS 解析,**zcode 晚启动或重建容器都不会让网关启动失败**。

### 三种网关,按需选(默认 A)

| 方案 | 怎么做 | 开销 |
|---|---|---|
| **A · nginx(默认)** | `docker compose up -d` | 镜像 ~20MB,内存约 5–10MB |
| **B · Caddy(功能多)** | `docker compose --profile caddy up -d`(另有自动 HTTPS、访问日志面板) | 镜像 ~24MB,内存约 20–40MB |
| **C · 零额外容器** | 不用代理:给 zcode-web 打开 `ports`,并设 `ZCODE_SERVER_AUTH_TOKEN=<随机串>`;首次访问 `http://host:3030/?token=<随机串>` 换 Cookie 即可(`/api` 与 `/ws` 都受保护) | 0 额外内存,但没有 TLS 终止、没有统一限速 |

要 HTTPS:方案 A 挂证书并打开 `nginx.conf` 里注释的两行(把端口映射到 443);方案 B 直接 `GATEWAY_TLS="tls you@example.com"`。
