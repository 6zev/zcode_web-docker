# zcode-web-docker

官方 ZCode Web(上游 [`zai-org/ZCode`](https://github.com/zai-org/ZCode),v3.17.2)的**单镜像 Docker 部署**:
一个容器里跑 Web UI + `@zcode/server`(HTTP/WS)+ Agent CLI `zcode.cjs`(stdio 拉起),单进程单端口。

镜像已由 GitHub Actions 构建并推送到 GHCR:

```bash
docker pull ghcr.io/6zev/zcode_web_docker:latest

docker run -d --name zcode-web -p 3030:3030 \
  -v zcode-data:/data \
  -v /你的/代码目录:/workspace \
  ghcr.io/6zev/zcode_web_docker:latest
```

打开 `http://<服务器IP>:3030/` → 完成 Z.ai OAuth 登录 → 开始用。凭据落在 `/data` 卷,重建容器不掉登录。

> 完整文档见 [DETAILED-README.md](DETAILED-README.md):构建细节、环境变量、验证方法、常见问题。

## 目录结构

| 文件 | 作用 |
|---|---|
| [Dockerfile](Dockerfile) | 两阶段:`builder`(克隆官方仓库 + 构建 server/web/agent)→ `runtime`(非 root、tini、HEALTHCHECK) |
| [docker-compose.yml](docker-compose.yml) | 一条命令起服务(`docker compose up -d --build`) |
| [docker-entrypoint.sh](docker-entrypoint.sh) | 准备数据目录、首次铺默认设置、打印启动诊断 |
| [zcode-preflight.sh](zcode-preflight.sh) | 镜像自检:产物 / 权限 / 网络 / 健康 |
| [.github/workflows/build-image.yml](.github/workflows/build-image.yml) | CI:hadolint 门禁 + 构建推送 GHCR + 单平台冒烟测试 |
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
- 卷 `/data` 必须持久化(HOME:凭据、会话库、插件缓存);`/workspace` 是 ZCode 的默认工作目录。
- 镜像默认以 **root** 运行,入口脚本会自动把 `/data` 与 `/workspace` 的属主修正为当前 UID,所以 bind mount 到新建的空目录也不会 `EACCES`。想跑非 root:`--user 1000:1000` + `sudo chown -R 1000:1000 <挂载目录>`。
