#!/bin/sh
# 网关(nginx)入口:渲染配置 → 生成 htpasswd → 自检 → 启动 nginx。
#
# 放在 /docker-entrypoint.d/ 下,由官方 nginx 镜像的 entrypoint 在启动前执行。
# 不依赖镜像自带的 envsubst 逻辑,这里自己 render 并带默认值(缺失变量也不会渲染成空值)。
#
# 变量:
#   ZCODE_UPSTREAM     上游,默认 zcode-web:3030
#   ZCODE_LISTEN_PORT  监听端口,默认 80
#   ZCODE_AUTH_REALM   Basic Auth 提示语,默认 ZCode
#   ZCODE_RATE         限速,默认 20r/s(挡暴力破解)
#   ZCODE_BURST        突发上限,默认 200(给小了浏览器首屏会 503)
#   ZCODE_AUTH_USER    用户名,默认 zcode
#   ZCODE_AUTH_PASSWORD 明文口令(用 openssl 现算 apr1),或 ZCODE_AUTH_HASH 直接给哈希
set -eu

TEMPLATE="/etc/nginx/nginx.conf.template"
TARGET="/etc/nginx/nginx.conf"
HTPASSWD="/etc/nginx/htpasswd"

if ! command -v envsubst >/dev/null 2>&1; then
  echo "[gateway] 缺少 envsubst(gettext),请用 nginx 官方镜像或自行安装 gettext" >&2
  exit 1
fi

: "${ZCODE_UPSTREAM:=zcode-web:3030}"
: "${ZCODE_LISTEN_PORT:=80}"
: "${ZCODE_AUTH_REALM:=ZCode}"
: "${ZCODE_RATE:=20r/s}"
: "${ZCODE_BURST:=200}"
: "${ZCODE_AUTH_USER:=zcode}"
export ZCODE_UPSTREAM ZCODE_LISTEN_PORT ZCODE_AUTH_REALM ZCODE_RATE ZCODE_BURST

echo "[gateway] 渲染 ${TEMPLATE} -> ${TARGET} (upstream=${ZCODE_UPSTREAM} listen=${ZCODE_LISTEN_PORT} rate=${ZCODE_RATE} burst=${ZCODE_BURST})"
envsubst '${ZCODE_UPSTREAM} ${ZCODE_LISTEN_PORT} ${ZCODE_AUTH_REALM} ${ZCODE_RATE} ${ZCODE_BURST}' \
  < "${TEMPLATE}" > "${TARGET}"

# ---- 口令 ----
if [ -n "${ZCODE_AUTH_HASH:-}" ]; then
  echo "[gateway] 使用外部提供的 ZCODE_AUTH_HASH(user=${ZCODE_AUTH_USER})"
  printf '%s:%s\n' "${ZCODE_AUTH_USER}" "${ZCODE_AUTH_HASH}" > "${HTPASSWD}"
elif [ -n "${ZCODE_AUTH_PASSWORD:-}" ]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "[gateway] 缺少 openssl,无法由口令生成哈希;请改传 ZCODE_AUTH_HASH,或换成带 openssl 的镜像" >&2
    exit 1
  fi
  echo "[gateway] 由 ZCODE_AUTH_PASSWORD 现算 apr1 哈希(user=${ZCODE_AUTH_USER})"
  printf '%s:%s\n' "${ZCODE_AUTH_USER}" "$(openssl passwd -apr1 "${ZCODE_AUTH_PASSWORD}")" > "${HTPASSWD}"
else
  echo "[gateway] 警告: 未设置 ZCODE_AUTH_PASSWORD / ZCODE_AUTH_HASH,回落到默认口令 zcode(请尽快改)"
  printf '%s:%s\n' "zcode" "$(openssl passwd -apr1 zcode)" > "${HTPASSWD}"
fi
chmod 644 "${HTPASSWD}"

# ---- 自检:配置有问题就带着原因退出,而不是起一个空转容器 ----
if ! nginx -t -c "${TARGET}" >/tmp/nginx-check.log 2>&1; then
  echo "[gateway] nginx -t 失败,配置内容如下:" >&2
  cat /tmp/nginx-check.log >&2
  exit 1
fi
sed -n '1,3p' /tmp/nginx-check.log

echo "[gateway] 就绪: 保护已开启(Basic Auth,含 /ws)"
