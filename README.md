
官方 ZCode Web(上游 [`zai-org/ZCode`](https://github.com/zai-org/ZCode),v3.17.2)的**单镜像 Docker 部署**:
一个容器里跑 Web UI + `@zcode/server`(HTTP/WS)+ Agent CLI `zcode.cjs`(stdio 拉起),单进程单端口。

镜像是单容器、单端口,访问保护直接用 **zcode 自带的令牌**(零额外容器、零额外内存):

```bash
cd /root/zcode-web-docker
cp .env.example .env
echo "ZCODE_SERVER_AUTH_TOKEN=$(openssl rand -hex 24)" >> .env   # 生成令牌(建议)
cat .env | grep TOKEN                                            # 记下它
docker compose up -d --build
# 首次访问: http://<服务器IP>:3030/?token=<令牌>   → 换成 Cookie 后正常用
```

不设令牌也能启动(方便本机试跑),但**容器启动日志会打印醒目警告**,端口就等于裸奔 ——
真要在无令牌状态下跑,请把 `BIND_HOST` 设成 `127.0.0.1`,别直接暴露到公网。

之后浏览器直接开 `http://<IP>:3030/` 即可(令牌已在 Cookie 里);换令牌会让所有旧 Cookie 立刻失效。
数据用 ZCode 原生默认 `~/.zcode`(命名卷 `zcode-data`),工作区就是 `/root`;重建容器不掉登录。

> 完整文档见 [DETAILED-README.md](DETAILED-README.md):构建细节、环境变量、验证方法、常见问题。

## 目录结构

| 文件 | 作用 |
|---|---|
| [docker-compose.yml](docker-compose.yml) | 一条命令起服务:仅 zcode-web(root,自带令牌保护) |
| [docker-entrypoint.sh](docker-entrypoint.sh) | 准备数据目录、首次铺默认设置、打印启动诊断 |
| [zcode-preflight.sh](zcode-preflight.sh) | 镜像自检:产物 / 权限 / 网络 / 健康 |
| [.github/workflows/build-image.yml](.github/workflows/build-image.yml) | CI:hadolint + 构建推送 GHCR + 容器冒烟 |
| [zcode-web.docker.json](zcode-web.docker.json) | 构建清单:版本、产物路径、运行期环境变量 |
| [DETAILED-README.md](DETAILED-README.md) | 完整文档:构建步骤、变量表、故障排查、实测记录 |
| [VERIFY-NOTES.md](VERIFY-NOTES.md) | 逐条源码核对记录(每条带 `file:line`) |

## CI 工作流

- **触发**:推 `main` / PR(只构建不推送)/ **每天 03:17 UTC 自动检查上游版本** / 手动触发(可选多平台、可强制重建)。
- **lint job**:hadolint(只卡 error)+ shell 语法 + compose/manifest 校验。
- **upstream job**:读 `zai-org/ZCode` 的 `package.json` 版本;定时任务先用 `docker manifest inspect` 查 GHCR,
  已有 `<版本>` tag 就直接跳过,没有才进入构建 —— 这样上游发新版本后会自动构建并推送新镜像。
- **build job**:Buildx 构建 → 推送 `ghcr.io/6zev/zcode_web_docker`(`latest` / `sha-<短SHA>` / `<上游版本>`,如 `3.17.2`)
  → 单平台且不推送时,额外 `load` 到本地跑**冒烟测试**(起容器 → 探活 `/api/server-info` 与首页 → 容器内自检脚本)。
- 构建缓存用 `type=gha`,重复构建会快很多。
- 部署端自动跟进:`docker compose pull && docker compose up -d`(compose 默认用 `latest`);
  想锁定版本就把 `IMAGE_TAG` 设成具体的上游版本号。

手动触发(强制重建)多平台:

```bash
gh workflow run build-image -f platforms=linux/amd64,linux/arm64 -f push_image=true -f force=true
```

## Python / 浏览器工具链

镜像内已装好(版本可用 build args 覆盖):

| 组件 | 版本 / 位置 | 说明 |
|---|---|---|
| Python 3 | Debian bookworm 自带(3.11),`python` / `python3` | `pip` 可直接装包(`PIP_BREAK_SYSTEM_PACKAGES=1`) |
| uv | `0.13.7`,`/usr/local/bin/uv`、`uvx` | 固定版本,可 `uv venv` / `uv pip install` / `uvx` |
| Playwright CLI | `1.59.1`(与上游 agent 的 playwright-core 对齐) | `playwright --version` |
| Playwright Chromium | `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright` | 含 `playwright install --with-deps chromium` 的完整系统依赖 |
| Chrome / Chromium | amd64 = Google Chrome stable;arm64 = Debian Chromium | `CHROME_BIN=/usr/local/bin/chrome` |

- ZCode 的 browser-use 会按 `executablePath → playwright → /usr/bin/google-chrome-stable → …` 自动找浏览器。
- 容器默认 root,Chrome 与 Playwright Chromium 以 root 启动必须 `--no-sandbox`;镜像用 wrapper 自动补上(**默认开启**),
- compose 已加 `shm_size: 1gb`,避免多标签页时 `/dev/shm` 不足崩溃。
- 例:`uvx --from playwright playwright --version`;Playwright 用系统 Chrome 时传 `channel="chrome"`。

## 环境要求

- 容器需能访问 `zcode.z.ai`、`api.z.ai`、`open.bigmodel.cn`(登录与推理);不通时给容器配 `HTTPS_PROXY`。
- 只用 Docker 跑镜像:**不需要**本地 Node/pnpm。要自己构建镜像:构建机需能出网,首次构建约 10–25 分钟
  (含 Python/uv/Chrome/Playwright 后体积与时间会再增加一些)。
- 数据用 ZCode 原生默认 `~/.zcode`(命名卷 `zcode-data`,含凭据、会话库、插件缓存);工作区即 `/root`(compose 把 `${WORKSPACE_DIR}` 挂到 `/root`)。

## 纯浏览器模式补丁

上游 standalone server 有意不做 "local host"(浏览器里 sidebar 的文件树/新建 project 会报
`project.host-offline` / `project.remote-project-required`,完整流程期望桌面客户端连入当 host)。
本镜像在构建时应用 [patches/standalone-web-local-host.patch](patches/standalone-web-local-host.patch):

- project service 把浏览器发来的 `hostId="local"` 归一到服务器自身身份 → 纯浏览器可浏览目录、创建 project、发起会话;
- `prepareSession` 对显式 `hostId="local"` 的请求放行(草稿目录落在 `ZCODE_SERVER_WORKSPACE`);
- 桌面远控语义不变:未带 hostId 的远端入口仍被拒绝,未知 host 仍报 `host-offline`。

已用 upstream 的 `createProjectService` 写单测验证(patch 前复现两个错误,patch 后 5/5 通过)。

