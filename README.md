# ZCode Web — Docker

在**一个容器**里跑官方 ZCode Web(上游仓库 [`zai-org/ZCode`](https://github.com/zai-org/ZCode) v3.17.2):
Web UI + `@zcode/server`(HTTP/WS)+ Agent CLI `zcode.cjs`(stdio 拉起)。单进程、单端口。

```
浏览器 ──HTTP/WS──▶ entry-http.js（@zcode/server，托管 packages/web/dist）
                         └── stdio ──▶ zcode.cjs app-server（ZCode Agent）
```

## 1. 快速开始

```bash
cd /root/zcode-web-docker
cp .env.example .env          # 按需改 WORKSPACE_DIR / 端口
docker compose up -d --build  # 首次:拉官方仓库 + 装依赖 + 构建(约 10–25 分钟)
```

打开 `http://<服务器IP>:3030/` → 点登录 → 在浏览器里完成 Z.ai OAuth
(容器需要能访问 `zcode.z.ai`)。凭据落在 `/data` 卷,`docker compose up -d --force-recreate`
不会掉登录。

不用 compose:

```bash
docker build -t zcode-web:3.17.2 .
docker run -d --name zcode-web -p 3030:3030 \
  -v zcode-data:/data \
  -v /你的/代码目录:/workspace \
  zcode-web:3.17.2
```

## 2. 目录内文件

| 文件 | 作用 |
|---|---|
| [Dockerfile](Dockerfile) | 两阶段:`builder`(克隆 + 构建)→ `runtime`(仅运行、非 root、含 HEALTHCHECK) |
| [docker-compose.yml](docker-compose.yml) | 一条命令起服务,端口映射,`/data` + `/workspace` 卷 |
| [docker-entrypoint.sh](docker-entrypoint.sh) | 准备数据目录、首次铺默认设置、打印启动诊断 |
| [zcode-preflight.sh](zcode-preflight.sh) | 镜像自检(产物/权限/网络/健康),进容器执行 |
| [.env.example](.env.example) | 构建/运行变量 |
| [zcode-web.docker.json](zcode-web.docker.json) | 清单:版本、产物路径、运行期环境变量 |
| [VERIFY-NOTES.md](VERIFY-NOTES.md) | 逐条源码核对记录(每条带 `file:line`),Dockerfile 的依据 |
| [screenshots/](screenshots) | 真实渲染验证的截图 |

## 3. 构建到底做了什么(照源码对齐上游)

```text
git clone --depth 1 zai-org/ZCode              # ARG ZCODE_REPO / ZCODE_REF
pnpm install                                   # 根 workspace(hoisted node_modules)
pnpm --dir apps/zcode-cli install              # 子 workspace(独立 lockfile)
node packages/desktop/scripts/prepare-agent-node-bundle.mjs   # → bundled-agents/linux-x64/glm/
pnpm --filter @zcode/server build              # → packages/server/dist/entry-http.js
pnpm --filter @zcode/web build                 # → packages/web/dist/
```

必须的构建期变量(已写进 Dockerfile):

- `ZCODE_ENV=production` —— 不设会静默注入**测试**内置 provider 配置(`zcode-builtin.test.json`)。
- `PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false` —— 否则 pnpm 会在子 workspace 执行 run 前自作主张 install。
- `HUSKY=0 CI=1` —— 仓库 `prepare` 钩子是 `husky && build:cua`,没有 `.git` 时必须关掉。
- `NODE_OPTIONS=--max-old-space-size=8192` —— agent/插件构建在低内存机器上会 OOM。
- Node `24.14.0` + pnpm `10.33.2`(对齐上游 `mise.toml`;Node ≥24 是硬要求,内置 `node:sqlite`)。
- 该步还需**构建期联网**:`prepare-agent-node-bundle.mjs` 会从 registry.npmjs.org 拉内置 npm tarball。

## 4. 运行期环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `3030` | HTTP 与 WS 同端口。注意:非法/0 会回落到 3030,不能随机端口 |
| `ZCODE_SERVER_HOST` | `0.0.0.0` | 绑定地址;置空时 hono 把 `undefined` 传给 `listen`,实际也是全部网卡 |
| `ZCODE_WEB_STATIC_ROOT` | `/app/packages/web/dist` | UI 静态根,必须含 `index.html`,且只能挂在 `/`(无 basePath) |
| `HOME` | `/data` | **决定** settings、session DB(`~/.zcode/cli/db`)、插件缓存 |
| `ZCODE_DATA_BASE_DIR` | `/data` | **决定** `{base}/.zcode/v2`(凭据、tasks-index、provider 配置) |
| `ZCODE_STORAGE_DIR` | `/data/.zcode` | 与默认值等价(exec/clipboard/SEA 用),保留无害 |
| `ZCODE_SERVER_WORKSPACE` | `/workspace` | 默认工作区(未设则取 `process.cwd()`) |
| `ZCODE_AGENT_SERVER_COMMAND` | `/app/agent/zcode.cjs` | Agent 入口;显式设置优先级最高 |
| `ZCODE_AGENT_SERVER_ARGS_JSON` | `["app-server","--stdio"]` | 必须是 JSON 字符串数组 |
| `ZCODE_SERVER_AUTH_TOKEN` | *(空)* | 设了之后 `/api/*`、`/ws` 要求令牌,首访需 `http://host:3030/?token=<值>` 换 Cookie |

> 只有 `HOME` + `ZCODE_DATA_BASE_DIR` 是**必须**成对设置的:`HOME` 管 settings/会话库,
> `ZCODE_DATA_BASE_DIR` 管 `v2/`。只设后者会让状态分裂到 `/root/.zcode` 与 `/data` 两处。
> 另:`ZCODE_SERVER_TOKEN` 是死变量(只影响 `/api/server-info` 自述),别用它当门禁。

卷:`/data`(必须持久化:登录、会话、插件缓存)、`/workspace`(你的代码)。

## 5. 构建后怎么验

```bash
docker compose ps                        # health: healthy
docker compose logs -f zcode-web         # [zcode-web] workspace=/workspace data=... port=3030 ...
docker compose exec zcode-web /usr/local/bin/zcode-preflight.sh
```

自检脚本会逐项检查:Node ≥24 与 `node:sqlite`、`entry-http.js`、`web/dist/index.html`、
Agent 入口与随包 `packages/bundled-skills`/`npm`、`/data` 与 `/workspace` 可写性、
`zcode.z.ai` 连通性、`/api/server-info` 与首页响应。

## 6. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 页面全 404,但端口是通的 | `ZCODE_WEB_STATIC_ROOT` 指向的目录里没有 `index.html`(web 构建失败或被裁剪)。最典型的静默失败 |
| 容器启动即退出,日志 `[zcode-server:http] startup failed` | 数据根不可写。`sudo chown -R 1000:1000 /宿主机/data 卷` 或 `--build-arg APP_UID=$(id -u) --build-arg APP_GID=$(id -g)` |
| UI 能开,发消息报 `agent server command is not configured` | `/app/agent/zcode.cjs` 缺失(build 阶段 agent bundle 未成功) |
| 官方插件、`/workflow` 技能缺失 | 只拷了单个 `zcode.cjs`。必须整目录拷 `bundled-agents/linux-x64/glm`(镜像里就是 `/app/agent`) |
| 登录/对话超时 | 容器出网不通:`zcode.z.ai`、`api.z.ai`、`open.bigmodel.cn`;在 `.env` 里配 `HTTPS_PROXY` |
| Agent 写不了 workspace(`EACCES`) | bind mount 属主不匹配,`sudo chown -R 1000:1000 <WORKSPACE_DIR>` |
| 设了 `ZCODE_SERVER_AUTH_TOKEN` 后 UI 连不上 ws | 首访必须带 `?token=` 换 Cookie;或直接不设令牌(默认) |
| 终端(terminal)不可用 | `node-pty` 无官方 linux 预编译,构建期靠 g++ 现场编译;失败只影响终端,不阻断启动 |
| 构建慢 / 拉不下来 | 换 `.env` 里的 `NPM_REGISTRY`,或在别的机器 build 后 `docker save` / `docker load` |

## 7. 已验证的东西(不是纸上谈兵)

在本机按 Dockerfile 里同样的步骤**原生跑了一遍**(Node 24 环境),结论:

| 环节 | 结果 |
|---|---|
| `pnpm install`(根 workspace) | ✅ 2m05s,`HUSKY=0` 生效,`node-pty` 原生模块编译通过 |
| `pnpm --filter @zcode/server build` | ✅ 产出 `packages/server/dist/entry-http.js`(5.6 MB) |
| `pnpm --filter @zcode/web build` | ✅ 产出 `packages/web/dist/index.html` + `assets/` |
| `prepare-agent-node-bundle.mjs` | ✅ 6m39s,产出 `bundled-agents/linux-x64/glm/`(75 MB,17 个官方插件 + bundled-skills + 内置 npm 12.2.0 + koffi) |
| 服务端启动 | ✅ 用 Dockerfile 里那套环境变量启动,`/api/server-info` = 200,首页 = 200,静态资源 = 200 |
| WebSocket | ✅ `ws://…/ws` 握手成功并收到服务端二进制帧 |
| UI 真实渲染 | ✅ headless Chrome 打开页面:`ZCode - Web + Server`,正文显示"连接 Z.AI / 连接 BigModel / 使用 API Key",**0 条控制台错误、0 个失败请求**(截图见 [screenshots/ui-3188.png](screenshots/ui-3188.png)) |
| Agent bundle | ✅ `zcode.cjs plugins list` 列出 16 个官方插件并成功从随包资源 seed 到 `$HOME/.zcode/cli/plugins/cache`;`app-server --stdio` 正常起停 |
| 镜像自检脚本 | ✅ 对着真实实例跑出 20 项全通过 |

仍未实测的部分(本沙箱没有 docker 命令):`docker build` 本身、容器内的非 root 权限与
HEALTHCHECK 行为。这三项都用 [zcode-preflight.sh](zcode-preflight.sh) 兜底检查。

## 8. 说明

- runtime 整树保留根 `node_modules`(pnpm 是「`.pnpm` 实体 + 顶层软链」的隔离布局,
  裁剪会让 `pty.node` 这类原生模块在运行时才报错),因此镜像偏大(约 2–4 GB)。
  换来的好处是与上游构建 1:1 一致:terminal / SSH / 浏览器工具都能用。
- 镜像按构建机架构自动归一化 agent 目录(`linux-x64` / `linux-arm64` → `/app/agent`),但
  builder 与 runtime 必须**同架构同 libc**(都用 bookworm),不要跨 arm64 或换 alpine。
- 不需要 Electron/Xvfb:上游 agent bundle 的设计就是用纯 Node 跑(`zcode.cjs app-server --stdio`)。
- UI 使用系统字体;需要完整 CJK/emoji 时给 runtime 阶段加 `fonts-noto-cjk fonts-noto-color-emoji`。
- 升级版本:改 `.env` 里 `ZCODE_REF` / `IMAGE_TAG` 后 `docker compose up -d --build`。
- 上游 `docs/web-app-docker-image.md` 描述的 "Node gateway 反代" 双层结构在当前源码里已不存在
  (`docker/` 目录与 `pnpm docker:build:web-app` 脚本都被删了),静态资源现在由 `entry-http` 自己托管,
  所以本 Dockerfile 是照源码重建的,不依赖那份文档里的脚本。
