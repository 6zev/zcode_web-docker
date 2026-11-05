# ZCode Web App Docker — 源码核对笔记

源: /tmp/zcsrc (main, package.json version 3.17.2)。node_modules 不在检出内;`@hono/node-server` 取自 registry tarball 1.19.14(版本由 pnpm-lock.yaml:1315-1319 解析)。
标记: [V]=已由源码验证 [U]=未能实测/推断。

## 1. entry-http 环境变量与监听地址

[V] packages/server/src/entry-http.ts:17 `port = Number(process.env["PORT"]) || 3030`(PORT=0/非法 → 3030,无法随机端口)。
[V] entry-http.ts:18 `host = ZCODE_SERVER_HOST?.trim() || HOST?.trim() || undefined`。
[V] entry-http.ts:19 `staticRoot = ZCODE_WEB_STATIC_ROOT?.trim()`;:20 `authToken = ZCODE_SERVER_AUTH_TOKEN?.trim()`;:28 `providerProvisioningTargetEnabled = Boolean(authToken)`。
[V] entry-http.ts:37-39 只有非空才传:无 host → 不传 host;无 staticRoot → 不挂静态;无 token → 不设 authRequired。
[V] http.ts:472 `serve({ fetch: app.fetch, hostname: options.host, port })`。
[V] @hono/node-server 1.19.14 `dist/index.mjs:649-651`:`serve=(options,l)=>{...server.listen(options?.port ?? 3e3, options.hostname, ...)}` — **没有任何 hostname 默认值**,undefined 原样交给 `net.Server.listen(port, undefined)` = 绑定全部网卡(Node 双栈下为 `::`,可接受 IPv4)。所以 **ZCODE_SERVER_HOST 未设 = 0.0.0.0 可外部访问**,不是 localhost。
[V] http.ts:475 日志行 `options.host?.trim() || "localhost"` 只是打印,**会误导**,不代表绑定地址。
[V] 其他被读的 env: ZCODE_SERVER_ID/NAME/WORKSPACE/TOKEN( http.ts:165,174-180,190 )。

## 2. 静态托管与鉴权

[V] http.ts:293-341 `resolveStaticFile`:`/`→`/index.html`;目录命中再拼 index.html;未命中且 `spaFallback` 且路径非受保护 → 回退 `<root>/index.html`。**没有 basename/base 配置项**,资源按绝对路径 `/assets/...` 解析,必须以 `/` 提供服务。
[V] 必须有 `index.html` 在 staticRoot 根(http.ts:331-339),否则全部 404;`spaFallback:true` 由 entry-http.ts:38 强制给。
[V] 只注册 `app.get("*")`(http.ts:456),非 GET 静态请求不走此分支。
[V] 受保护路径仅 `/ws`、`/ws/*`、`/api/*`(http.ts:264-266);静态资源不鉴权(:358 `!isTokenProtectedPath || validToken`)。
[V] token 校验: Bearer / `?token=`(回写 HttpOnly cookie `zcode_lite_token`) / cookie(http.ts:245-262)。
[V] **未设 ZCODE_SERVER_AUTH_TOKEN 时完全无鉴权**:`app.use("*")` 中间件不注册(http.ts:353-364),/api/* 与 /ws 全开;Web UI 正常可用(`/api/server-info` 无 token 直接 200)。
[V] 设了 token 时:UI 静态页仍可加载,`/api/server-info` 401 → web 端静默降级(packages/web/src/main.tsx:455-464 `!response.ok` 直接返回默认 wsUrl),但 `/ws` 升级会被 401,需先 `?token=` 拿 cookie。→ Docker 默认建议不设 token,或明确要求 `http://host:3030/?token=...` 首访。
[V] 坑:http.ts:190 `authRequired: options.authRequired ?? Boolean(ZCODE_SERVER_TOKEN)` — 若只设 ZCODE_SERVER_TOKEN 而不设 AUTH_TOKEN,server-info 自称需要鉴权但实际不校验(死变量)。

## 3. 构建序列核对

环境 [V]: package.json `packageManager: pnpm@10.33.2`、`engines.node >=24`;mise.toml `node = "24.14.0" / pnpm = "10.33.2"`;apps/zcode-cli/package.json `engines.node 24.14.0`;scripts/assert-node-version.mjs 要求 major>=24。仓库自带参考镜像 `Dockerfile.desktop-e2e:8,10` = `node:24.14.0-bookworm` + `PNPM_VERSION=10.33.2`。

- [V] 根 `pnpm install` — **必需**。附带 `prepare` 脚本 `husky && pnpm build:cua`(package.json:20)→ 无 .git 时设 `HUSKY=0`(参考镜像 Dockerfile.desktop-e2e:12-13 也设 `CI=1 HUSKY=0`)。
- [U] `pnpm install` in apps/zcode-cli — **不必要**。根 pnpm-lock.yaml 已把 `apps/zcode-cli:166` 与 `apps/zcode-cli/packages/*`(31 个 importer,如 :411)纳入根 workspace;默认构建路径(build-desktop-agent-cli.mjs 非 turbo 分支)明确用**根** `pnpm --filter <pkg> build`。留着无害但会生成第二份 node_modules;不要用它替代根 install。
- [V] `node packages/desktop/scripts/prepare-agent-node-bundle.mjs` — **必需**,但它**自己会构建 CLI bundle 与全部官方插件 runtime**(:323 buildCliBundle → scripts/build-desktop-agent-cli.mjs;:516-523 主流程)。所以**不需要**另外 `pnpm --filter @zcode/cli build`。产物:`packages/desktop/bundled-agents/linux-x64/glm/{zcode.cjs,.node-bundle-meta.json,packages/*-plugin/,packages/bundled-skills/,npm/}`,源为 `apps/zcode-cli/packages/cli/dist/zcode.cjs`(stage-agent-bundle.mjs:14,32-64)。注意它 `rmSync(glmDir)` 后重建(stage-agent-bundle.mjs:55),且需网络下载 `npm@12.2.0` tarball(bundled-npm-assets.mjs:16,21,29)。sharp 阶段会被跳过(见 §6)。
- [V] `pnpm --filter @zcode/server build` — **必需**:`tsup && pnpm run build:remote`(packages/server/package.json:15-16)→ `packages/server/dist/entry-http.js`(tsup.config.ts:65-66)+ `packages/server/dist/remote/zcode-server.cjs`(build-remote.ts:37,entry-http 不需要)。
- [V] `pnpm --filter @zcode/web build` — **必需**(vite build)→ `packages/web/dist/`(无 outDir 覆盖,index.html 源自 packages/web/index.html)。
- [V] 顺序:web/server 构建与 agent bundle 互不依赖,可并行;agent bundle 必须在 runtime 阶段被完整复制。

## 4. Agent 接线

[V] `packages/zcode-server-cli/src/runtime/agentWiring.ts:9-48` 只**产出** env(`ZCODE_AGENT_SERVER_COMMAND` / `_ARGS_JSON`),且仅被 `@zcode/server-cli` 使用(main.ts:4-12、cli.ts:457)。**entry-http.js 完全不走这段代码**,不会自动接线。
[V] 真正读取点:`packages/services/src/zcode-agent/zcodeAgentProcessManager.ts:456-465`(`ZCODE_AGENT_SERVER_COMMAND`、`ZCODE_AGENT_SERVER_ARGS_JSON`(必须 JSON 字符串数组,:311-320)、`ZCODE_AGENT_SERVER_CWD`),由 :608 `commandResolver ?? resolveDefaultZCodeAgentCommand` 进入;调用链 entry-http.ts:23-29 → createServerHostServices(services/src/node.ts:3275) → createLocalServices → ProcessManager。
[V] 优先级:env 显式覆盖 > monorepo 源码/dist > Electron runtime > 已部署 native binary(:468-478)。显式设置即为最高优先级,**会被采纳**。
[V] 是否"足够":`spawn(command, args, {cwd, detached,...})`(:1172)不做 shell 解释。`zcode.cjs` 带 `#!/usr/bin/env node` banner 且 chmod 0o755(build.mjs:176,215)→ 直接给 `/app/tools/zcode.cjs` 可执行;更稳的写法是 `ZCODE_AGENT_SERVER_COMMAND=$(command -v node)` + `ARGS='["/app/tools/zcode.cjs","app-server","--stdio"]'`。**不足的部分**:官方插件/bundled-skills 按 `dirname(process.argv[1])` 就近查找(`bootstrap/src/app/bundled-plugins.ts:669-687`、`bundled-skills.ts:44-49`),只放一个 zcode.cjs 会丢官方插件与 `/workflow` 技能包(非致命,仅 warn + 空列表,bundled-skills.ts:73-84)。→ 建议整目录复制 `bundled-agents/linux-x64/glm` 到 `/app/agent/`,命令指向其中的 zcode.cjs。

## 5. 数据目录

[V] `ZCODE_DATA_BASE_DIR` → `services/src/paths.ts:14,37-43`;`getZCodeDataRootDir = {base}/.zcode`(:46-48);`getAppConfigDir = {base}/.zcode/v2`(:56-58)。默认 base = `HOME || homedir()`(:15)。
[V] **settings/task index 不读 ZCODE_DATA_BASE_DIR**:`setting/settingService.ts:52-60,236` 用 `ZCODE_DESKTOP_HOME_DIR || HOME || USERPROFILE || homedir()` + `/.zcode/v2/setting.json`。→ HOME 必须一起设,否则 settings 与其它数据分叉。
[V] credentials:`credential/credentialService.ts:28-34` → `{getAppConfigDir()}/credentials.json` = `{base}/.zcode/v2/credentials.json`。
[V] server 启动期写:`{base}/.zcode/v2/runtime/provider/bundled/zcode-builtin.json`(provider-node/src/zcode-builtin-provider-config-materializer.ts:24-35,mkdir recursive,所以目录必须可写)。
[V] task index:`{base}/.zcode/v2/tasks-index.sqlite`(paths.ts:206-208)。
[V] `ZCODE_STORAGE_DIR` **不参与**上面这些路径;agent 侧 session DB 来自 CLI 配置默认值 `storage.dir = "~/.zcode"`、`sessionDbPath = "~/.zcode/cli/db/db.sqlite"`(apps/zcode-cli/packages/contracts/src/config/index.ts:301-304),`~` 由 `homedir()` 展开(file-config.adapter.ts:68-73)→ 实际是 **HOME** 决定。ZCODE_STORAGE_DIR 只影响 exec/clipboard/SEA runtime-tools 等(adapters/src/exec/execution-utils.ts:19、cli/src/clipboard-image.ts:33)。插件缓存 `{storageRoot}/cli/plugins`(bootstrap/src/app/paths.ts:5-11),默认即 `{HOME}/.zcode/cli/plugins`。
[V] 结论:`HOME=/data` + `ZCODE_DATA_BASE_DIR=/data` 是**正确且必需**的一对;`ZCODE_STORAGE_DIR=/data/.zcode` 与默认值等价(幂等,保留无害,**但非必要**)。
[U] 若只设 ZCODE_DATA_BASE_DIR 不设 HOME:任务/凭据进 /data,settings 与 agent session DB 进 /root/.zcode — 状态分裂,属必避坑。

## 6. 运行期原生依赖

[V] `packages/server/tsup.config.ts:35-59` 显式 external: ssh2, node-pty, undici, axios, form-data, combined-stream, proxy-from-env, follow-redirects, yazl, yauzl, node-forge, yaml;`noExternal` 只 bundle @zcode/{shared,rpc,services,client}(:73)。其余 deps(tsup 默认 skipNodeModulesBundle)同样保持 external: hono, @hono/node-server, @hono/node-ws, ws, 以及上表全部 → **运行时必须有 node_modules**。
[V] `.npmrc` = `node-linker=hoisted`(bundled-npm-assets.mjs:4 注释亦确认)→ 根 node_modules 为扁平布局,复制整个仓库树(含 node_modules)最稳妥;只拷根 node_modules 通常够,但冲突版本会有嵌套目录,不建议裁剪。
[V] 原生 .node:node-pty 1.1.0 官方包**无 linux prebuild**(stageDependencies.ts:210-212 注释),linux 发行打包时明确换成 `@lydell/node-pty-linux-x64`(:215-233)。容器内两条路:pnpm-workspace.yaml:29 `allowBuilds: node-pty: true` → 安装时用 g++/python3 现场编译(参考镜像装了 g++,Dockerfile.desktop-e2e:36);或沿用 @lydell 平台包替换。缺 pty.node 不阻断启动(terminalService.ts:31 dynamic import 才加载,失败仅终端不可用)。
[V] cpu-features 0.0.10 随 ssh2,allowBuilds 编译;缺失 ssh2 仍可用。koffi 2.15.6 仅 CLI/CUA 插件用,包内自带多平台预编译。**sharp 不在本树**(pnpm-lock.yaml 中 0 命中)→ prepare 脚本的 sharp 阶段自动跳过。
[V] builder 阶段 linux/x64 产物复制到同平台 runtime:可行(同 arch + 同 glibc,建议两阶段都用 bookworm-slim;不要跨 arm64/glibc→alpine)。

## 7. Web 构建额外 env

[V] 不需要 VITE_*;`ZCODE_ENV` 可选,默认 `"test"`(vite.config.ts:26-28),endpoint/oauth 常量在构建期注入(:96-110);`WEB_REMOTE_FRONTEND_VERSION`、`ZCODE_COMMIT` 可选(:98,101)。产物 `packages/web/dist/`,base 未设置 = `/`。
[V] 服务端同理:`scripts/builtin-provider-config.mjs:37-43` 无 ZCODE_ENV 时回落到 .env* 再默认 `test`,并写入 `__ZCODE_ENV__`(tsup.config.ts:24-28,85)。生产镜像**应显式 `ZCODE_ENV=production`** 构建两处,否则内置 provider 配置取自 `config/provider/zcode-builtin.test.json`。

## 8. 启动硬性要求 / 阻塞项

1. [V] 数据根可写:entry-http 在建服务前就物化 builtin provider 配置(entry-http.ts:13-16 → materializer:31-35),失败即 `process.exitCode=1`(`[zcode-server:http] startup failed`)。
2. [V] 无 `ZCODE_AGENT_SERVER_COMMAND` 时不会崩,但首个会话抛 `ZCode agent server command is not configured.`(zcodeAgentProcessManager.ts:1116-1118,1532)。
3. [V] 无 `ZCODE_WEB_STATIC_ROOT`(或目录无 index.html)时:端口能开,页面全 404,无报错 — 最容易静默失败的一项。
4. [V] Node ≥24(node:sqlite 内置,tsup.config.ts:70 `removeNodeProtocol:false`;本沙箱 node 24.22 下 `require('node:sqlite')` 正常)。无需 --experimental 标志。
5. [V] 端口:默认 3030,单端口(HTTP + WS 同端口,injectWebSocket http.ts:478)。无独立 WS 端口。
6. [V] 登录/OAuth/权益:不阻塞进程启动,只影响能否真正对话;未设 token 时 `ProviderProvisioning` 目标服务被禁用(entry-http.ts:28 → node.ts:3317)。
7. [V] 工作区:`ZCODE_SERVER_WORKSPACE` 未设则用 `process.cwd()`(http.ts:173-180)→ 镜像里 `WORKDIR /workspace` 并预建。
8. [V] 插件运行时:agent 端官方插件 dist 必须已在 glm/packages 下(prepare 脚本负责),否则首启 seed 为空。

## 9. docs/web-app-docker-image.md 与现状

[V] 该文档 §运行结构(:9-31)描述的 "Node gateway → /api,/ws 反代 → entry-http" 双层结构**已不存在**:`docker/` 目录整体缺失(无 `docker/web-app/start.mjs`);`pnpm docker:build:web-app` / `docker:run:web-app` 在根 package.json 中**不存在**(只剩 `test:docker:web-app-gateway`,package.json:33,而 scripts/test-web-app-gateway-reset.mjs:12 硬引用那个缺失的 start.mjs → 该测试当前必然 ENOENT)。
[V] 现状是单进程:entry-http 自身用 `ZCODE_WEB_STATIC_ROOT` + `spaFallback` 托管 web dist(entry-http.ts:38,http.ts:455-470),不再需要网关/反代。
[V] 文档仍准确的部分:builder 步骤清单(:36-40)、`NODE_BASE_IMAGE` 默认 node:24-bookworm-slim、单端口 3030、runtime 需保留 pnpm 依赖、数据布局 `v2` / `cli`(:28-30)、HOME/ZCODE_DATA_BASE_DIR/ZCODE_STORAGE_DIR 三件套(:46-48)。
[V] 影响:重建镜像只能照源码写 Dockerfile,不能照文档跑脚本;文档里的 gateway 层、seed 脚本(setting.json 缺失时 seed /workspace)都需自己实现或省略。

## 10. 逐条纠正摘要

- 监听地址:未设 ZCODE_SERVER_HOST = 0.0.0.0(node listen(port, undefined)),日志里的 "localhost" 是假象。
- ZCODE_STORAGE_DIR 不决定 session DB / settings;HOME 才决定。三件套里只有 HOME + ZCODE_DATA_BASE_DIR 是必需的。
- apps/zcode-cli 的独立 install 与 `pnpm --filter @zcode/cli build` 都不是必需步骤(prepare 脚本内部已构建)。
- 只拷 zcode.cjs 到 /app/tools 会丢官方插件与 bundled-skills;应整体拷贝 glm 目录。
- ZCODE_ENV 不设即 "test" —— 不报错但构建出测试环境常量。
- 不建议设 ZCODE_SERVER_AUTH_TOKEN 而又不处理 `?token=`,否则 /ws 401。