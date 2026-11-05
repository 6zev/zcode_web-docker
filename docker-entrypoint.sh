#!/usr/bin/env bash
# ZCode Web 容器入口:准备持久化目录、铺默认配置、权限自愈,然后交给 CMD 启动服务。
set -euo pipefail

DATA_DIR="${ZCODE_DATA_BASE_DIR:-${ZCODE_DATA_DIR:-/root/zcode/data}}"
ZCODE_DIR="${DATA_DIR}/.zcode"
WORKSPACE_DIR="${ZCODE_WORKSPACE:-/root/zcode/workspace}"
FIX_OWNERSHIP="${ZCODE_FIX_OWNERSHIP:-1}"
TARGET_UID="${ZCODE_APP_UID:-1000}"
TARGET_GID="${ZCODE_APP_GID:-1000}"

log() { printf '[zcode-web] %s\n' "$*"; }
die() { printf '[zcode-web] 错误: %s\n' "$*" >&2; exit 1; }

export HOME="${HOME:-/root}"
export ZCODE_DATA_BASE_DIR="${DATA_DIR}"
export ZCODE_STORAGE_DIR="${ZCODE_STORAGE_DIR:-${ZCODE_DATA_BASE_DIR}/.zcode}"

running_as_root() { [ "$(id -u)" = "0" ]; }

# 把设置文件按需铺好(两条分支共用)
provision_settings() {
  SETTINGS="${ZCODE_DIR}/v2/setting.json"
  if [ ! -f "${SETTINGS}" ]; then
    log "初始化默认设置 -> ${SETTINGS}"
    printf '{\"workspace\": \"%s\",\n  \"theme\": \"dark\"\n}\n' "${WORKSPACE_DIR}" > "${SETTINGS}" 2>/dev/null || \
      log "警告: 设置写入失败,服务会以默认值继续"
  fi
}

# 1) 以 root 启动(镜像默认):修正挂载目录属主后直接以 root 运行。
#    若显式设置 ZCODE_DROP_PRIVILEGES=1,则 chown 之后 setpriv 降权到 ZCODE_APP_UID:ZCODE_APP_GID。
if running_as_root; then
  if [ "${FIX_OWNERSHIP}" = "1" ]; then
    mkdir -p "${ZCODE_DIR}/v2" "${ZCODE_DIR}/cli" "${ZCODE_DIR}/logs" "${WORKSPACE_DIR}"
    log "以 root 启动:把 ${DATA_DIR} 与 ${WORKSPACE_DIR} 的属主修正为 ${TARGET_UID}:${TARGET_GID}"
    chown -R "${TARGET_UID}:${TARGET_GID}" "${DATA_DIR}" "${WORKSPACE_DIR}" 2>/dev/null || \
      log "警告: chown 失败(可能是 NFS / 只读挂载),下面会以 root 继续"
  fi
  provision_settings
  if [ "${ZCODE_DROP_PRIVILEGES:-0}" = "1" ] && command -v setpriv >/dev/null 2>&1; then
    log "降权到 ${TARGET_UID}:${TARGET_GID} 运行"
    exec setpriv --reuid "${TARGET_UID}" --regid "${TARGET_GID}" --init-groups "$@"
  fi
  log "以 root 运行(UID $(id -u));如需非 root 请用 --user 1000:1000"
  exec "$@"
fi

# 2) 非 root:准备目录,不可写就明确报错(而不是让服务半死)
mkdir -p "${ZCODE_DIR}/v2" "${ZCODE_DIR}/cli" "${ZCODE_DIR}/logs" "${WORKSPACE_DIR}" 2>/dev/null || true
if [ ! -w "${ZCODE_DIR}" ]; then
  log "警告: ${ZCODE_DIR} 不可写 —— 宿主机上的挂载目录属主是 $(stat -c '%u:%g' "${DATA_DIR}" 2>/dev/null || echo '?'),而容器内是 UID $(id -u)。"
  log "        修复方式三选一:"
  log "          1) 以 root 启动让入口脚本自愈:docker run --user 0:0 ...(compose 去掉 user: 即可)"
  log "          2) sudo chown -R $(id -u):$(id -g) <宿主机上的数据目录>"
  log "          3) 改用命名卷: -v zcode-data:/root/zcode/data(Docker 会把镜像内该目录的属主复制给卷)"
  die "数据目录不可写,启动会失败(entry-http 在建服务前就要写 ${ZCODE_DIR}/v2)"
fi

# 3) 首次运行的默认工作区,不覆盖已有设置
provision_settings

# 4) 关键路径自检,失败就明确报错而不是静默 404
ENTRY="${ZCODE_ENTRY:-/app/packages/server/dist/entry-http.js}"
STATIC_ROOT="${ZCODE_WEB_STATIC_ROOT:-/app/packages/web/dist}"
[ -f "${ENTRY}" ] || log "错误: 缺少服务端入口 ${ENTRY}(镜像构建不完整)"
[ -f "${STATIC_ROOT}/index.html" ] || log "警告: 未找到前端静态资源 ${STATIC_ROOT}/index.html"
[ -x "${ZCODE_AGENT_SERVER_COMMAND:-/app/agent/zcode.cjs}" ] || log "警告: agent 入口不可执行 ${ZCODE_AGENT_SERVER_COMMAND:-/app/agent/zcode.cjs}"

log "workspace=${WORKSPACE_DIR} data=${ZCODE_DIR} port=${ZCODE_PORT:-3030} host=${ZCODE_SERVER_HOST:-0.0.0.0} agent=${ZCODE_AGENT_SERVER_COMMAND:-auto}"
log "首次使用请在浏览器打开 http://<host>:${ZCODE_PORT:-3030}/ 完成 Z.ai OAuth 登录(容器需能访问 zcode.z.ai)"

exec "$@"
