# syntax=docker/dockerfile:1.7
#
# ZCode Web (官方 zai-org/ZCode Web App) 单镜像 Dockerfile
#
#   浏览器 --HTTP/WS--> entry-http.js (@zcode/server, 静态托管 packages/web/dist)
#                          `-- stdio --> zcode.cjs app-server (ZCode Agent CLI)
#
# 构建:  docker build -t zcode-web:3.17.2 .
# 运行:  docker run -d --name zcode-web -p 3030:3030 \
#          -v zcode-data:/data -v "$PWD/workspace:/workspace" zcode-web:3.17.2
# 访问:  http://<host>:3030/        （登录走 Z.ai OAuth，需容器能访问 zcode.z.ai）
#
# 上游版本对齐: Node 24.14.0 / pnpm 10.33.2（mise.toml）、ZCode v3.17.2

ARG NODE_BASE_IMAGE=node:24.14.0-bookworm
ARG PNPM_VERSION=10.33.2
ARG APP_UID=1000
ARG APP_GID=1000

# ============================================================================
# Stage 1 · builder —— 装依赖 + 构建 web 静态资源、server、agent bundle
# ============================================================================
FROM ${NODE_BASE_IMAGE} AS builder

ARG PNPM_VERSION=10.33.2
ARG ZCODE_REPO=https://github.com/zai-org/ZCode.git
ARG ZCODE_REF=main
ARG NPM_REGISTRY=https://registry.npmjs.org/
# 上游构建脚本会在内存受限机器上 OOM，官方自建链路把上限提到 8G
ARG NODE_HEAP_MB=8192

ENV CI=1 \
    HUSKY=0 \
    ZCODE_ENV=production \
    TURBO_TELEMETRY_DISABLED=1 \
    PNPM_HOME=/pnpm \
    PNPM_STORE_DIR=/pnpm/store \
    PNPM_CONFIG_STORE_DIR=/pnpm/store \
    PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false \
    PNPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NODE_OPTIONS=--max-old-space-size=${NODE_HEAP_MB} \
    PATH=/pnpm:/usr/local/bin:/usr/bin:/bin

# 原生依赖（node-pty / koffi / sharp / ssh2 等）与 git、打包工具链
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends \
      bash ca-certificates curl git openssh-client \
      procps xz-utils unzip zip tar \
      build-essential pkg-config python3; \
    rm -rf /var/lib/apt/lists/*

RUN corepack enable && corepack prepare "pnpm@${PNPM_VERSION}" --activate

WORKDIR /app

# 源码。默认从官方仓库浅克隆。
# 要构建本地检出：把下面这段 RUN 换成 `COPY . /app/`（.dockerignore 已排除 .git 与 node_modules）。
RUN git clone --depth 1 --branch "${ZCODE_REF}" "${ZCODE_REPO}" /app \
 && rm -rf /app/.git \
 && git config --global --add safe.directory /app


# 根 workspace 安装(含 apps/zcode-cli 及其 packages 作为 importer)。
# 加 retry:pnpm 10 在容器构建里偶发 ERR_PNPM_ENOENT(rename .../_tmp_* -> .../esbuild),
# 属瞬时文件系统问题,重试即可。PUPPETEER_SKIP_DOWNLOAD:仓库里带了 puppeteer,
# 这里用不到它自带的 Chromium(省 ~200MB 与数分钟)。
ENV PUPPETEER_SKIP_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

RUN --mount=type=cache,id=zcode-pnpm-store,target=/pnpm/store \
    set -eux; \
    for attempt in 1 2 3; do \
      echo "[zcode-web] pnpm install (attempt ${attempt}/3)"; \
      pnpm install --no-frozen-lockfile && break; \
      if [ "${attempt}" = "3" ]; then echo "[zcode-web] pnpm install 连续 3 次失败" >&2; exit 1; fi; \
      rm -rf /app/node_modules /app/packages/*/node_modules /app/apps/*/node_modules; \
      sleep 10; \
    done; \
    pnpm --version

# 注意:不要在这里对子 workspace 再跑 `pnpm --dir apps/zcode-cli install`。
# apps/zcode-cli 的 pnpm-workspace.yaml 只声明 packages/* 与 tools/*,而它的 packages/adapters
# 依赖根 workspace 的包(如 @zcode/model-option-map = workspace:*),单独在子目录 install 会报
# ERR_PNPM_WORKSPACE_PKG_NOT_FOUND(CI 与本地均实测复现)。上面这一次根 install 已经把
# apps/zcode-cli 及其 packages 作为 importer 全部装好,agent bundle 构建脚本走的也是根 node_modules。

RUN node /app/packages/desktop/scripts/prepare-agent-node-bundle.mjs

# 服务端（HTTP/WS + 静态托管）与前端静态资源
RUN pnpm --filter @zcode/server build \
 && pnpm --filter @zcode/web build

# 产物自检 + 归一化 agent 目录。按构建机架构选 linux-x64 / linux-arm64 后落到固定路径,
# runtime 阶段就不必关心架构,也不会误拷错平台目录。
RUN set -eux; \
    test -f /app/packages/server/dist/entry-http.js; \
    test -f /app/apps/zcode-cli/packages/cli/dist/zcode.cjs; \
    test -f /app/packages/web/dist/index.html; \
    case "$(uname -m)" in \
      x86_64|amd64) AGENT_KEY=linux-x64 ;; \
      aarch64|arm64) AGENT_KEY=linux-arm64 ;; \
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    test -f "/app/packages/desktop/bundled-agents/${AGENT_KEY}/glm/zcode.cjs"; \
    rm -rf /opt/zcode-agent; \
    mkdir -p /opt/zcode-agent; \
    cp -a "/app/packages/desktop/bundled-agents/${AGENT_KEY}/glm/." /opt/zcode-agent/; \
    test -f /opt/zcode-agent/zcode.cjs; \
    echo "[zcode-web] build artifacts ok (agent=${AGENT_KEY})"

# ============================================================================
# Stage 2 · runtime —— 只留运行期需要的产物与依赖，非 root 运行
# ============================================================================
FROM ${NODE_BASE_IMAGE} AS runtime

ARG APP_UID=1000
ARG APP_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_ENV=production \
    ZCODE_ENV=production \
    TZ=Asia/Saigon \
    ZCODE_PORT=3030 \
    ZCODE_HOST=0.0.0.0 \
    ZCODE_SERVER_HOST=0.0.0.0 \
    ZCODE_WEB_STATIC_ROOT=/app/packages/web/dist \
    HOME=/root \
    ZCODE_AGENT_SERVER_COMMAND=/app/agent/zcode.cjs \
    ZCODE_AGENT_SERVER_ARGS_JSON='["app-server","--stdio"]' \
    ZCODE_WORKSPACE=/workspace \
    ZCODE_SERVER_WORKSPACE=/workspace \
    ZCODE_FIX_OWNERSHIP=1 \
    ZCODE_DROP_PRIVILEGES=0

# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends \
      bash ca-certificates curl git openssh-client \
      procps tini util-linux; \
    rm -rf /var/lib/apt/lists/*; \
    groupmod -o -g "${APP_GID}" node; \
    usermod -o -u "${APP_UID}" -g "${APP_GID}" -d /data -s /bin/bash -m node

WORKDIR /workspace

# 服务端与依赖。entry-http.js 把 hono / ws / ssh2 / node-pty / undici / axios / form-data /
# yaml / node-forge 等全部 external 化，运行期必须有完整 node_modules。
# pnpm 默认是「只留 symlink」的隔离布局（.pnpm 实体 + 顶层软链），所以整树复制、不做裁剪：
# 少拷一个 .node 原生模块，症状要等到运行时才暴露（终端不可用等）。
COPY --from=builder /app/package.json /app/package.json
COPY --from=builder /app/pnpm-lock.yaml /app/pnpm-lock.yaml
COPY --from=builder /app/pnpm-workspace.yaml /app/pnpm-workspace.yaml
COPY --from=builder /app/node_modules /app/node_modules
COPY --from=builder /app/packages/server /app/packages/server
COPY --from=builder /app/packages/web/dist /app/packages/web/dist
# Agent：上游勾选的 <platform>-<arch>/glm 整目录就位。插件与 bundled-skills 由 CLI 按
# dirname(zcode.cjs) 就近解析，只拷单个 zcode.cjs 会丢官方插件与 /workflow 技能包。
COPY --from=builder /opt/zcode-agent /app/agent
COPY --from=builder /app/apps/zcode-cli/package.json /app/apps/zcode-cli/package.json

# 数据卷：/data 是 HOME（凭据、会话库、插件缓存），/workspace 是默认工作目录
RUN set -eux; \
    mkdir -p /data /workspace /app/agent; \
    chown -R "$(id -u):$(id -g)" /app /data /workspace; \
    chmod +x /app/agent/zcode.cjs; \
    if find /app/node_modules -name 'pty.node' -print -quit | grep -q .; then \
      echo "[zcode-web] node-pty 原生模块就位"; \
    else \
      echo "[zcode-web] 警告: 未找到 pty.node,容器内终端功能会不可用" >&2; \
    fi

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY zcode-preflight.sh /usr/local/bin/zcode-preflight.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/zcode-preflight.sh

VOLUME ["/data", "/workspace"]
EXPOSE 3030

# 运行身份:默认 root(容器内需要写挂载卷、装东西、改属主都最省事)。
# 想回到非 root:--user 1000:1000 或 compose 里写 user: "1000:1000",
# 此时把挂载目录 chown 到 1000:1000 即可(或先以 root 起一次让它自愈)。
USER root

# 未启用访问令牌时 /api/server-info 可直接探活；若设置了 ZCODE_SERVER_AUTH_TOKEN，
# 该路径会 401，此时探首页静态资源（静态资源不受令牌保护）。
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${ZCODE_PORT}/api/server-info" -o /dev/null \
      || curl -fsS "http://127.0.0.1:${ZCODE_PORT}/" -o /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "/app/packages/server/dist/entry-http.js"]
