#!/usr/bin/env bash
# ZCode Web 容器入口:准备持久化目录、铺默认配置、访问保护提示,然后交给 CMD 启动服务。
# 本镜像始终以 root 运行;数据用 ZCode 原生默认 ~/.zcode,工作区默认 $HOME(/root)。
set -euo pipefail

ZCODE_DIR="${ZCODE_DATA_BASE_DIR:+${ZCODE_DATA_BASE_DIR%/}/.zcode}"
ZCODE_DIR="${ZCODE_DIR:-${HOME:-/root}/.zcode}"
WORKSPACE_DIR="${ZCODE_WORKSPACE:-${ZCODE_SERVER_WORKSPACE:-${HOME:-/root}}}"

log() { printf '[zcode-web] %s\n' "$*"; }

export HOME="${HOME:-/root}"

# 把设置文件按需铺好
provision_settings() {
  SETTINGS="${ZCODE_DIR}/v2/setting.json"
  if [ ! -f "${SETTINGS}" ]; then
    log "初始化默认设置 -> ${SETTINGS}"
    printf '{"workspace": "%s",\n  "theme": "dark"\n}\n' "${WORKSPACE_DIR}" > "${SETTINGS}" 2>/dev/null || \
      log "警告: 设置写入失败,服务会以默认值继续"
  fi
}

# ---- 0) 访问保护提示(不阻止启动) ----
if [ -z "${ZCODE_SERVER_AUTH_TOKEN:-}" ]; then
  log "=================================================================================="
  log "警告: 未设置 ZCODE_SERVER_AUTH_TOKEN —— 本服务没有访问保护(仅建议本机试跑)"
  log "      任何能连到 ${ZCODE_PORT:-3030} 端口的人都可以调用 /api/* 与 /ws,"
  log "      包括改配置、跑命令、读写 ${WORKSPACE_DIR} 里的代码。"
  log "      只在本机用: 把端口映射改成 127.0.0.1(compose 里设 BIND_HOST=127.0.0.1)"
  log "      要给内网/公网用: 生成令牌后重启 ——"
  log "          export ZCODE_SERVER_AUTH_TOKEN=\$(openssl rand -hex 24)"
  log "        首次访问 http://<host>:${ZCODE_PORT:-3030}/?token=<令牌> 即换成 Cookie"
  log "=================================================================================="
else
  log "访问保护: 已启用令牌(/api/* 与 /ws 需要令牌;首次访问 /?token=<令牌> 换 Cookie)"
fi

# ---- 1) 准备 ZCode 原生数据目录(~/.zcode)与工作区 ----
mkdir -p "${ZCODE_DIR}/v2" "${ZCODE_DIR}/cli" "${ZCODE_DIR}/logs" "${WORKSPACE_DIR}"
provision_settings

# ---- 2) 关键路径自检,失败就明确报错而不是静默 404 ----
ENTRY="${ZCODE_ENTRY:-/app/packages/server/dist/entry-http.js}"
STATIC_ROOT="${ZCODE_WEB_STATIC_ROOT:-/app/packages/web/dist}"
[ -f "${ENTRY}" ] || log "错误: 缺少服务端入口 ${ENTRY}(镜像构建不完整)"
[ -f "${STATIC_ROOT}/index.html" ] || log "警告: 未找到前端静态资源 ${STATIC_ROOT}/index.html"
[ -x "${ZCODE_AGENT_SERVER_COMMAND:-/app/agent/zcode.cjs}" ] || log "警告: agent 入口不可执行 ${ZCODE_AGENT_SERVER_COMMAND:-/app/agent/zcode.cjs}"

log "UID=$(id -u),始终以 root 运行;data=${ZCODE_DIR}(ZCode 原生 ~/.zcode) workspace=${WORKSPACE_DIR} port=${ZCODE_PORT:-3030} host=${ZCODE_SERVER_HOST:-0.0.0.0} agent=${ZCODE_AGENT_SERVER_COMMAND:-auto}"
log "首次使用请在浏览器打开 http://<host>:${ZCODE_PORT:-3030}/ 完成 Z.ai OAuth 登录(容器需能访问 zcode.z.ai)"

exec "$@"
