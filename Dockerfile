# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# 运行时镜像：不预置 Xray，由 entrypoint 在容器启动时下载 + 校验
# 好处：镜像小（~20MB）、每次启动可用最新版、架构无关（单镜像多架构）
# ---------------------------------------------------------------------------
FROM alpine:3.20

LABEL org.opencontainers.image.title="x-cf" \
      org.opencontainers.image.description="VLESS + XHTTP (REALITY / TLS-CDN) node, env-var driven, Xray fetched at startup" \
      org.opencontainers.image.source="https://github.com/ly921002/x-cf"

RUN apk add --no-cache \
      ca-certificates \
      curl \
      unzip \
      tzdata \
      openssl

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ---- 默认值（全部可被 docker run -e / compose environment 覆盖）----
ENV MODE=reality \
    XRAY_PORT=443 \
    XRAY_VERSION=latest \
    XRAY_FORCE_UPDATE=false \
    XHTTP_PATH_BASE=/api/v1 \
    XHTTP_PATH_LEN=8 \
    XHTTP_MODE=auto \
    FLOW= \
    XRAY_ENCRYPTION_GROUP=pq \
    XHTTP_PADDING=100-1000 \
    TRUSTED_XFF_HEADER=CF-Connecting-IP \
    TZ=Asia/Shanghai

# 凭据与二进制缓存目录（挂载后重建容器不会失效、不会重复下载）
VOLUME ["/data"]

EXPOSE 443

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD sh -c 'nc -z 127.0.0.1 "${XRAY_PORT:-443}"'

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
