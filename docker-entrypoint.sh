#!/usr/bin/env bash
# ZCode Web 容器入口：准备持久化目录、铺默认配置，然后交给 CMD 启动服务。
set -euo pipefail

DATA_DIR="${ZCODE_DATA_BASE_DIR:-/data}"
ZCODE_DIR="${DATA_DIR}/.zcode"
WORKSPACE_DIR="${ZCODE_WORKSPACE:-/workspace}"

log() { printf '[zcode-web] %s\n' "$*"; }

# 1. 持久化目录（挂载空卷时属主会是 root，这里兜一次）
export HOME="${HOME:-/data}"
export ZCODE_DATA_BASE_DIR="${ZCODE_DATA_BASE_DIR:-/data}"
export ZCODE_STORAGE_DIR="${ZCODE_STORAGE_DIR:-${ZCODE_DATA_BASE_DIR}/.zcode}"

mkdir -p "${ZCODE_DIR}/v2" "${ZCODE_DIR}/cli" "${ZCODE_DIR}/logs" "${WORKSPACE_DIR}" 2>/dev/null || true
if [ ! -w "${ZCODE_DIR}" ]; then
  log "警告: ${ZCODE_DIR} 不可写（卷属主不是 UID $(id -u)）。可执行: sudo chown -R $(id -u):$(id -g) <宿主机挂载目录>"
fi

# 2. 首次运行的默认工作区，不覆盖已有设置
SETTINGS="${ZCODE_DIR}/v2/setting.json"
if [ ! -f "${SETTINGS}" ]; then
  log "初始化默认设置 -> ${SETTINGS}"
  printf '{\n  "workspace": "%s",\n  "theme": "dark"\n}\n' "${WORKSPACE_DIR}" > "${SETTINGS}" 2>/dev/null || \
    log "设置写入失败（目录不可写），服务仍会以默认值继续"
fi

# 3. 关键路径自检，失败就明确报错而不是静默 404
ENTRY="${ZCODE_ENTRY:-/app/packages/server/dist/entry-http.js}"
STATIC_ROOT="${ZCODE_WEB_STATIC_ROOT:-/app/packages/web/dist}"
[ -f "${ENTRY}" ] || log "错误: 缺少服务端入口 ${ENTRY}（镜像构建不完整）"
[ -f "${STATIC_ROOT}/index.html" ] || log "警告: 未找到前端静态资源 ${STATIC_ROOT}/index.html"

log "workspace=${WORKSPACE_DIR} data=${ZCODE_DIR} port=${ZCODE_PORT:-3030} host=${ZCODE_SERVER_HOST:-0.0.0.0} agent=${ZCODE_AGENT_SERVER_COMMAND:-auto}"
log "首次使用请在浏览器打开 http://<host>:${ZCODE_PORT:-3030}/ 完成 Z.ai OAuth 登录（容器需能访问 zcode.z.ai）"

exec "$@"
