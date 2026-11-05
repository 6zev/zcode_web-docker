#!/usr/bin/env bash
# ZCode Web 镜像自检:不需要浏览器、不需要登录,验证"镜像本身是否完整"。
# 用法:docker compose exec zcode-web /usr/local/bin/zcode-preflight.sh
set -uo pipefail

PASS=0; FAIL=0
ok()   { printf '  [ok]   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  [warn] %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }
ok_or_bad() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

section "进程 / Node"
printf '  [info] 运行身份: UID=%s GID=%s (%s)\n' "$(id -u)" "$(id -g)" "$(id -un 2>/dev/null || echo '?')"
ok_or_bad "node 可执行 ($(node -v 2>/dev/null))" "node -v"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "${NODE_MAJOR}" -ge 24 ]; then ok "node major >= 24(node:sqlite 需要)"; else bad "node major=${NODE_MAJOR} < 24"; fi
ok_or_bad "node:sqlite 可用" "node -e 'require(\"node:sqlite\")'"

section "服务端产物"
ENTRY="${ZCODE_ENTRY:-/app/packages/server/dist/entry-http.js}"
[ -f "${ENTRY}" ] && ok "入口 ${ENTRY}" || bad "缺少入口 ${ENTRY}"
STATIC="${ZCODE_WEB_STATIC_ROOT:-/app/packages/web/dist}"
[ -f "${STATIC}/index.html" ] && ok "前端静态根 ${STATIC}/index.html" || bad "缺少 ${STATIC}/index.html(页面会全 404)"
[ -d "${STATIC}/assets" ] && ok "静态资源目录 assets/" || warn "没有 ${STATIC}/assets(可能是构建被裁剪)"

section "Agent"
CMD="${ZCODE_AGENT_SERVER_COMMAND:-/app/agent/zcode.cjs}"
[ -f "${CMD}" ] && ok "agent 入口 ${CMD}" || bad "缺少 agent 入口 ${CMD}(首个会话会报 'agent server command is not configured')"
[ -x "${CMD}" ] && ok "agent 入口可执行位" || warn "agent 入口无执行位(Node spawn 直调时多可用)"
AGENT_DIR="$(dirname "${CMD}")"
for d in packages packages/bundled-skills node-runtime/npm .node-bundle-meta.json; do
  [ -e "${AGENT_DIR}/${d}" ] && ok "随包资源 ${d}" || warn "缺少 ${d}(插件/技能/内置 npm 相关能力会降级)"
done
ARGS_JSON="${ZCODE_AGENT_SERVER_ARGS_JSON:-[\"app-server\",\"--stdio\"]}"
if node -e "const a=JSON.parse(process.argv[1]); process.exit(Array.isArray(a)?0:1)" "${ZCODE_AGENT_SERVER_ARGS_JSON:-[\"app-server\",\"--stdio\"]}" >/dev/null 2>&1; then
  ok "ZCODE_AGENT_SERVER_ARGS_JSON 是 JSON 字符串数组"
else
  bad "ZCODE_AGENT_SERVER_ARGS_JSON 不是合法 JSON 数组"
fi

section "数据目录"
for d in "${HOME:-/data}" "${ZCODE_DATA_BASE_DIR:-/data}" "${ZCODE_STORAGE_DIR:-/data/.zcode}" "/workspace"; do
  if [ -d "${d}" ]; then
    if [ -w "${d}" ]; then ok "可写 ${d}"; else bad "不可写 ${d}(启动会 exitCode 1 或 agent 无法落库)"; fi
  else
    warn "不存在 ${d}"
  fi
done

section "网络(登录 / 推理需要)"
if command -v curl >/dev/null 2>&1; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://zcode.z.ai/ 2>/dev/null)"
  case "${code}" in
    ""|000) warn "zcode.z.ai 不可达 —— 需要 HTTPS_PROXY 才能登录/对话";;
    *) ok "zcode.z.ai 可达 (HTTP ${code})";;
  esac
fi

section "服务端健康"
PORT="${PORT:-${ZCODE_PORT:-3030}}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/api/server-info" 2>/dev/null)"
case "${code}" in
  200) ok "/api/server-info = 200";;
  401) warn "/api/server-info = 401(已启用 ZCODE_SERVER_AUTH_TOKEN,属正常;首个页面需 ?token= 换 Cookie)";;
  ""|000) bad "连不上 127.0.0.1:${PORT}(服务未启动或绑错地址)";;
  *) warn "/api/server-info = ${code}";;
esac
root_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/" 2>/dev/null)"
[ "${root_code}" = "200" ] && ok "首页 / = 200" || warn "首页 / = ${root_code}"

printf '\n---- 自检结果: %d 项通过, %d 项失败 ----\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
