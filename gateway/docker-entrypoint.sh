#!/bin/sh
# 网关容器入口:把口令换算成 Caddy 能用的 bcrypt+base64 哈希,然后交给 caddy run。
#
# 优先级:
#   1) ZCODE_AUTH_HASH 已设置   → 直接用(自备 bcrypt 哈希,或 base64 后的 bcrypt)
#   2) ZCODE_AUTH_PASSWORD 有值 → 容器内现算(caddy hash-password + base64)
#   3) 都没有                   → 回落到 Caddyfile 里的默认哈希(口令 `zcode`,仅用于试跑)
set -eu

AUTH_USER="${ZCODE_AUTH_USER:-zcode}"
AUTH_PASSWORD="${ZCODE_AUTH_PASSWORD:-}"
AUTH_HASH="${ZCODE_AUTH_HASH:-}"

if [ -z "${AUTH_HASH}" ] && [ -n "${AUTH_PASSWORD}" ]; then
  echo "[gateway] 用 ZCODE_AUTH_PASSWORD 现算 bcrypt 哈希(user=${AUTH_USER})"
  AUTH_HASH="$(caddy hash-password --plaintext "${AUTH_PASSWORD}" | base64 | tr -d '\n')"
elif [ -n "${AUTH_HASH}" ]; then
  echo "[gateway] 使用外部提供的 ZCODE_AUTH_HASH(user=${AUTH_USER})"
else
  echo "[gateway] 警告: 未设置 ZCODE_AUTH_PASSWORD / ZCODE_AUTH_HASH,回落到默认口令 zcode(请尽快修改)"
fi

if [ -n "${AUTH_HASH}" ]; then
  export ZCODE_AUTH_HASH="${AUTH_HASH}"
fi

echo "[gateway] upstream=${ZCODE_UPSTREAM:-zcode-web:3030} listen=${ZCODE_LISTEN:-:80} tls=${ZCODE_TLS:-<off>}"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
