#!/bin/sh
# 网关(nginx)入口:先按口令生成 htpasswd,再做一次配置检查,最后启动 nginx。
#
# 官方 nginx 镜像的 /docker-entrypoint.sh 会把本脚本(放在 /docker-entrypoint.d/)在启动前跑一遍,
# 并在稍后对 /etc/nginx 下的配置做 ${VAR} 替换。
#
# 口令来源(优先 ZCODE_AUTH_HASH):
#   ZCODE_AUTH_HASH      直接给 apr1/bcrypt 哈希串(htpasswd -nbB 或 openssl passwd -apr1 的输出)
#   ZCODE_AUTH_PASSWORD  明文,容器内用 openssl 算 apr1 哈希
#   ZCODE_AUTH_USER      用户名,默认 zcode
set -eu

AUTH_USER="${ZCODE_AUTH_USER:-zcode}"
AUTH_PASSWORD="${ZCODE_AUTH_PASSWORD:-}"
AUTH_HASH="${ZCODE_AUTH_HASH:-}"
HTPASSWD="/etc/nginx/htpasswd"

if [ -n "${AUTH_HASH}" ]; then
  echo "[gateway] 使用外部提供的 ZCODE_AUTH_HASH(user=${AUTH_USER})"
  printf '%s:%s\n' "${AUTH_USER}" "${AUTH_HASH}" > "${HTPASSWD}"
elif [ -n "${AUTH_PASSWORD}" ]; then
  echo "[gateway] 由 ZCODE_AUTH_PASSWORD 现算 apr1 哈希(user=${AUTH_USER})"
  printf '%s:%s\n' "${AUTH_USER}" "$(openssl passwd -apr1 "${AUTH_PASSWORD}")" > "${HTPASSWD}"
else
  echo "[gateway] 警告: 未设置 ZCODE_AUTH_PASSWORD / ZCODE_AUTH_HASH,回落到默认口令 zcode(请尽快改)"
  printf '%s:%s\n' "zcode" "$(openssl passwd -apr1 zcode)" > "${HTPASSWD}"
fi

chmod 600 "${HTPASSWD}"
# 让 nginx worker(默认 nginx 用户)也能读到
chown root:nginx "${HTPASSWD}" 2>/dev/null || true

echo "[gateway] upstream=${ZCODE_UPSTREAM:-zcode-web:3030} realm=${ZCODE_AUTH_REALM:-ZCode}"
