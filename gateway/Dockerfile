# 网关镜像:官方 nginx:alpine + openssl(curl 仅用于健康检查)
#
# nginx:alpine 里没有 openssl 命令(只有库),而网关入口要用它把明文口令算成 apr1 哈希,
# 所以这里只加一个包。不需要 openssl 时可以跳过本镜像,直接用官方镜像 + 传 ZCODE_AUTH_HASH:
#   docker run --rm nginx:1.27-alpine sh -c 'apk add --no-cache openssl >/dev/null && openssl passwd -apr1 "你的口令"'
FROM nginx:1.27-alpine

RUN apk add --no-cache openssl curl

# 配置模板与入口脚本由 compose 挂载;这里不 COPY,方便改完直接重启容器生效
