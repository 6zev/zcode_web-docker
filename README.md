# zcode-web-docker

官方 ZCode Web(上游 [`zai-org/ZCode`](https://github.com/zai-org/ZCode),v3.17.2)的**单镜像 Docker 部署**:
一个容器里跑 Web UI + `@zcode/server`(HTTP/WS)+ Agent CLI `zcode.cjs`(stdio 拉起),单进程单端口。

镜像是单容器、单端口,访问保护直接用 **zcode 自带的令牌**(零额外容器、零额外内存):

```bash
cd /root/zcode-web-docker
cp .env.example .env
echo "ZCODE_SERVER_AUTH_TOKEN=$(openssl rand -hex 24)" >> .env   # 生成令牌
cat .env | grep TOKEN                                            # 记下它
docker compose up -d --build
# 首次访问: http://<服务器IP>:3030/?token=<令牌>   → 换成 Cookie 后正常用
```

之后浏览器直接开 `http://<IP>:3030/` 即可(令牌已在 Cookie 里);换令牌会让所有旧 Cookie 立刻失效。
凭据落在 `/root/zcode/data` 卷,重建容器不掉登录。

> 完整文档见 [DETAILED-README.md](DETAILED-README.md):构建细节、环境变量、验证方法、常见问题。

## 目录结构

| 文件 | 作用 |
|---|---|
| [Dockerfile](Dockerfile) | 两阶段:`builder`(克隆官方仓库 + 构建 server/web/agent)→ `runtime`(非 root、tini、HEALTHCHECK) |
| [docker-compose.yml](docker-compose.yml) | 一条命令起服务:gateway(对外入口)+ zcode-web(内部) |
| [gateway/nginx.conf.template](gateway/nginx.conf.template) | **默认网关**配置模板:Basic Auth + 反代 + WebSocket + 限速 |
| [gateway/Dockerfile](gateway/Dockerfile) | 网关镜像:nginx:1.27-alpine + openssl(约 25MB) |
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

## 访问保护

默认方案:**用 zcode 自带的令牌**(`ZCODE_SERVER_AUTH_TOKEN`),不需要任何代理容器。

```
浏览器 ──?token=<令牌>(一次)──▶ Cookie ──▶ zcode-web:3030
                                  /api/* 与 /ws 全部校验令牌
```

- 令牌保护的是 `/api/*` 与 `/ws`(也就是所有真实数据和操作);静态页面本身不含数据。
- 三种带令牌的方式:`?token=<令牌>`(会写 Cookie,最方便)、`Authorization: Bearer <令牌>`、或 Cookie。
- 令牌没配时 `docker compose up` **直接报错**,不会静默变成公开服务。
- 令牌留在 `./token/token.txt`(bind mount,方便随时查看/轮换)。
- 轮换:改 `.env` 里的值 → `docker compose up -d zcode-web`。

### 需要 TLS / 限速 / 只开一个端口时,再加网关(可选)

| 方案 | 命令 | 开销 |
|---|---|---|
| **默认 · 只用令牌** | `docker compose up -d` | 0(无额外容器) |
| nginx 网关(反代 + Basic Auth + 限速) | `docker compose --profile nginx up -d` | 镜像 ~25MB,内存 ~5–10MB |
| Caddy 网关(自动 HTTPS) | `docker compose --profile caddy up -d` | 镜像 ~24MB,内存 ~20–40MB |

开着网关时,建议把 compose 里 zcode-web 的 `ports:` 注释掉,只留网关端口,避免绕过网关直连 3030(令牌仍然有效,属于双保险)。
