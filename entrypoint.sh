#!/bin/sh
# ============================================================================
#  x-cf 容器入口 —— 全部行为由环境变量控制
#
#  核心变量：
#    MODE                  reality | cdn
#    XRAY_PORT             容器内监听端口（默认 443）
#    XRAY_VERSION          latest 或指定版本如 v26.10.31（默认 latest）
#    XRAY_FORCE_UPDATE     true 时忽略缓存重新下载（默认 false）
#    XRAY_DOWNLOAD_BASE    下载源前缀，可换镜像加速（默认官方 GitHub）
#
#  reality 模式：
#    SNI                   伪装域名（必填，需支持 TLS1.3 + h2）
#    SERVER_IP             节点地址（留空自动探测公网 IP）
#    SHORT_ID              自定义 shortId（留空随机生成并持久化）
#    PRIVATE_KEY           自定义私钥（留空自动生成；会自动推导公钥）
#    DEST                  自定义回落目标 host:port（默认 ${SNI}:443）
#
#  cdn 模式：
#    DOMAIN                你的域名（必填）
#    CERT_FILE             证书路径（默认 /cert/cert.pem）
#    KEY_FILE              私钥路径（默认 /cert/key.key）
#    CFIP                  客户端连接的优选 IP（留空用 DOMAIN）
#    CFPORT                客户端连接的 CF 端口（默认 443）
#
#  通用：
#    UUID                  自定义 UUID（留空自动生成并持久化）
#    XHTTP_PATH            自定义完整 path（留空按 BASE+LEN 随机生成）
#    XHTTP_PATH_BASE       路径前缀（默认 /api/v1）
#    XHTTP_PATH_LEN        随机路径长度（默认 8，0 表示只用 BASE）
#    XHTTP_MODE            auto | packet-up | stream-up | stream-one
#    FLOW                  xtls-rprx-vision 或留空（默认空，不启用）
#    XHTTP_PADDING         填充范围如 100-1000（留空关闭）
#    XRAY_ENCRYPTION_GROUP pq | x25519
#    VLESS_NAME            链接备注名
#    WORKDIR               数据目录（默认 /data）
#    DRY_RUN               true 时只打印配置和链接，不启动
# ============================================================================
set -eu

WORKDIR="${WORKDIR:-/data}"
XRAY_BIN="$WORKDIR/xray"
ASSET_DIR="/usr/local/share/xray"

# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------
die()  { printf '\033[31m[!]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 变量默认值与规整
# ---------------------------------------------------------------------------
MODE="${MODE:-reality}"
XRAY_PORT="${XRAY_PORT:-443}"
XRAY_VERSION="${XRAY_VERSION:-latest}"
XRAY_FORCE_UPDATE="${XRAY_FORCE_UPDATE:-false}"
XRAY_DOWNLOAD_BASE="${XRAY_DOWNLOAD_BASE:-https://github.com/XTLS/Xray-core/releases}"

SNI="${SNI:-}"
SERVER_IP="${SERVER_IP:-}"
SHORT_ID="${SHORT_ID:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
DEST="${DEST:-}"

DOMAIN="${DOMAIN:-}"
CERT_FILE="${CERT_FILE:-/cert/cert.pem}"
KEY_FILE="${KEY_FILE:-/cert/key.key}"
CFIP="${CFIP:-}"
CFPORT="${CFPORT:-}"

UUID="${UUID:-}"
XHTTP_PATH="${XHTTP_PATH:-}"
XHTTP_PATH_BASE="${XHTTP_PATH_BASE:-/api/v1}"
XHTTP_PATH_LEN="${XHTTP_PATH_LEN:-8}"
XHTTP_MODE="${XHTTP_MODE:-auto}"
XHTTP_PADDING="${XHTTP_PADDING:-}"
FLOW="${FLOW:-}"
XRAY_ENCRYPTION_GROUP="${XRAY_ENCRYPTION_GROUP:-pq}"
VLESS_NAME="${VLESS_NAME:-}"
DRY_RUN="${DRY_RUN:-false}"

# flow 只有 xtls-rprx-vision 一个合法值；非法值会让 xray 拒绝启动
case "$FLOW" in
  ""|none) FLOW="" ;;
  xtls-rprx-vision) ;;
  *) die "FLOW 只能是 xtls-rprx-vision 或留空（none），当前: $FLOW" ;;
esac

mkdir -p "$WORKDIR"
cd "$WORKDIR"

case "$MODE" in
  reality|cdn) ;;
  *) die "MODE 只能是 reality 或 cdn，当前: $MODE" ;;
esac

# ---------------------------------------------------------------------------
# JSON 转义 / URI 转义
# ---------------------------------------------------------------------------
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

uri_escape() {
  # 用 | 作分隔符避免 / 冲突；替换里的 & 需转义为 \& (否则表示"整个匹配")
  printf '%s' "$1" | sed 's|:|%3A|g; s|/|%2F|g; s|#|%23|g; s|?|%3F|g; s|\&|%26|g'
}

# ---------------------------------------------------------------------------
# 随机值
# ---------------------------------------------------------------------------
rand_alnum() {
  tr -dc 'A-Za-z0-9' < /dev/urandom | dd bs=1 count="$1" 2>/dev/null
}

rand_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    h="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    printf '%s-%s-%s-%s-%s\n' \
      "$(printf '%s' "$h" | cut -c1-8)"  "$(printf '%s' "$h" | cut -c9-12)" \
      "$(printf '%s' "$h" | cut -c13-16)" "$(printf '%s' "$h" | cut -c17-20)" \
      "$(printf '%s' "$h" | cut -c21-32)"
  fi
}

# ---------------------------------------------------------------------------
# Xray 下载（容器启动时执行）
#   - 已存在且版本匹配 -> 直接用缓存
#   - XRAY_FORCE_UPDATE=true 或版本不匹配 -> 重新下载
# ---------------------------------------------------------------------------
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    armv7l|armv7)  die "不支持 32 位 ARM，请使用 64 位系统" ;;
    *)             die "不支持的架构: $(uname -m)（仅 amd64 / arm64）" ;;
  esac
}

xray_usable() {
  [ -f "$XRAY_BIN" ] && [ -x "$XRAY_BIN" ] \
    && [ "$(stat -c %s "$XRAY_BIN" 2>/dev/null || echo 0)" -gt 1000000 ]
}

cached_version() {
  [ -s "$WORKDIR/xray.version" ] && cat "$WORKDIR/xray.version" || echo ""
}

want_version() {
  if [ "$XRAY_VERSION" = "latest" ]; then
    # latest 用远端 tag 判断是否需要更新；取不到就退化为"有缓存就用"
    url="$XRAY_DOWNLOAD_BASE/latest"
    tag="$(curl -fsSL --connect-timeout 8 -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null \
           | sed 's|.*/||' || true)"
    if [ -n "$tag" ]; then echo "$tag"; else echo "latest"; fi
  else
    echo "$XRAY_VERSION"
  fi
}

download_xray() {
  WANT_VER="$(want_version)"

  if [ "$XRAY_FORCE_UPDATE" != "true" ] && xray_usable; then
    HAVE_VER="$(cached_version)"
    if [ -z "$HAVE_VER" ] || [ "$XRAY_VERSION" = "latest" ] || [ "$HAVE_VER" = "$WANT_VER" ]; then
      info "使用缓存的 Xray（$("$XRAY_BIN" version 2>/dev/null | head -n1 || echo unknown)）"
      return 0
    fi
  fi

  case "$XRAY_ARCH" in
    64)        ZIP="Xray-linux-64.zip" ;;
    arm64-v8a) ZIP="Xray-linux-arm64-v8a.zip" ;;
  esac

  if [ "$XRAY_VERSION" = "latest" ]; then
    BASE="$XRAY_DOWNLOAD_BASE/latest/download"
  else
    BASE="$XRAY_DOWNLOAD_BASE/download/$XRAY_VERSION"
  fi

  info "下载 Xray: $BASE/$ZIP"
  curl -fL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
       --progress-bar -o xray.zip "$BASE/$ZIP" \
    || die "Xray 下载失败（检查网络或设置 XRAY_DOWNLOAD_BASE 换源）"

  # SHA256 校验（官方 .dgst 格式为 "SHA2-256= <hex>"）
  if curl -fsSL --retry 3 --connect-timeout 15 -o xray.dgst "$BASE/$ZIP.dgst" 2>/dev/null; then
    want="$(awk -F'= ' '/^SHA2-256=/ {print $2}' xray.dgst | tr -d ' \r\n')"
    got="$(sha256sum xray.zip | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      rm -f xray.zip xray.dgst
      die "XRAY 校验失败！期望 $want 实际 $got —— 拒绝使用"
    fi
    info "SHA256 校验通过"
  else
    warn "无法获取 .dgst，跳过校验（如需强制校验请自行设置镜像）"
  fi

  unzip -q -o xray.zip xray || die "解压失败"
  chmod +x xray 2>/dev/null || true
  rm -f xray.zip xray.dgst

  # geo 数据放到镜像内的固定位置
  if [ -f geoip.dat ] && [ -d "$ASSET_DIR" ]; then mv -f geoip.dat "$ASSET_DIR/" 2>/dev/null || true; fi
  if [ -f geosite.dat ] && [ -d "$ASSET_DIR" ]; then mv -f geosite.dat "$ASSET_DIR/" 2>/dev/null || true; fi

  if ! xray_usable; then
    die "Xray 不可用：$(
      if [ ! -f xray ]; then echo 文件不存在;
      elif [ "$(stat -c %s xray 2>/dev/null || echo 0)" -lt 1000000 ]; then echo 文件过小;
      elif [ ! -x xray ]; then echo 缺少可执行权限（noacl 挂载？）;
      else echo 未知原因; fi)"
  fi

  printf '%s' "$WANT_VER" > xray.version
  info "Xray 就绪: $("$XRAY_BIN" version | head -n1)"
}

# ---------------------------------------------------------------------------
# 凭据：优先 env -> 其次缓存 -> 最后新建
# ---------------------------------------------------------------------------
load_or_create_uuid() {
  if [ -n "$UUID" ]; then printf '%s' "$UUID" > uuid.txt; echo "$UUID"; return; fi
  if [ -s uuid.txt ]; then cat uuid.txt; return; fi
  v="$(rand_uuid)"; printf '%s' "$v" > uuid.txt; echo "$v"
}

random_path() {
  if [ "${XHTTP_PATH_LEN:-0}" -gt 0 ] 2>/dev/null; then
    printf '%s/%s' "$XHTTP_PATH_BASE" "$(rand_alnum "$XHTTP_PATH_LEN")"
  else
    printf '%s' "$XHTTP_PATH_BASE"
  fi
}

load_or_create_path() {
  if [ -n "$XHTTP_PATH" ]; then printf '%s' "$XHTTP_PATH" > xhttp_path.txt; echo "$XHTTP_PATH"; return; fi
  if [ -s xhttp_path.txt ]; then cat xhttp_path.txt; return; fi
  v="$(random_path)"; printf '%s' "$v" > xhttp_path.txt; echo "$v"
}

load_or_create_vlessenc() {
  case "$XRAY_ENCRYPTION_GROUP" in
    pq|x25519) ;;
    *) die "XRAY_ENCRYPTION_GROUP 只能是 pq 或 x25519，当前: $XRAY_ENCRYPTION_GROUP" ;;
  esac
  dek_f="enc_dekey.$XRAY_ENCRYPTION_GROUP.txt"
  enk_f="enc_enkey.$XRAY_ENCRYPTION_GROUP.txt"

  if [ -s "$dek_f" ] && [ -s "$enk_f" ]; then
    DEKEY="$(cat "$dek_f")"; ENKEY="$(cat "$enk_f")"; return
  fi

  "$XRAY_BIN" vlessenc > enc.json
  if [ "$XRAY_ENCRYPTION_GROUP" = "pq" ]; then
    # 最后一组 = ML-KEM-768（后量子安全）
    DEKEY="$(awk -F'"' '/decryption/ {print $4}' enc.json | tail -1)"
    ENKEY="$(awk -F'"' '/encryption/ {print $4}' enc.json | tail -1)"
  else
    # 第一组 = X25519
    DEKEY="$(awk -F'"' '/decryption/ {print $4}' enc.json | head -1)"
    ENKEY="$(awk -F'"' '/encryption/ {print $4}' enc.json | head -1)"
  fi
  rm -f enc.json

  [ -n "$DEKEY" ] || die "无法解析 decryption"
  [ -n "$ENKEY" ] || die "无法解析 encryption"
  printf '%s' "$DEKEY" > "$dek_f"
  printf '%s' "$ENKEY" > "$enk_f"
}

load_or_create_reality_keys() {
  if [ -n "$PRIVATE_KEY" ]; then
    out="$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" 2>&1)" || die "PRIVATE_KEY 非法"
    PRIVATE_KEY="$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
    PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F': ' '/PublicKey|Password/ {print $2; exit}')"
    [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || die "无法从 PRIVATE_KEY 推导密钥对"
    printf '%s' "$PRIVATE_KEY" > private_key.txt
    printf '%s' "$PUBLIC_KEY"  > public_key.txt
    return
  fi
  if [ -n "$PUBLIC_KEY" ]; then die "只给了 PUBLIC_KEY，服务端需要 PRIVATE_KEY"; fi
  if [ -s private_key.txt ] && [ -s public_key.txt ]; then
    PRIVATE_KEY="$(cat private_key.txt)"; PUBLIC_KEY="$(cat public_key.txt)"; return
  fi

  out="$("$XRAY_BIN" x25519 2>/dev/null)"
  PRIVATE_KEY="$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F': ' '/PublicKey|Password/ {print $2; exit}')"
  [ -n "$PRIVATE_KEY" ] || die "生成私钥失败"
  [ -n "$PUBLIC_KEY" ]  || die "生成公钥失败"
  printf '%s' "$PRIVATE_KEY" > private_key.txt
  printf '%s' "$PUBLIC_KEY"  > public_key.txt
}

load_or_create_short_id() {
  if [ -n "$SHORT_ID" ]; then printf '%s' "$SHORT_ID" > short_id.txt; echo "$SHORT_ID"; return; fi
  if [ -s short_id.txt ]; then cat short_id.txt; return; fi
  v="$(dd if=/dev/urandom bs=1 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  printf '%s' "$v" > short_id.txt
  echo "$v"
}

detect_public_ip() {
  if [ -n "$SERVER_IP" ]; then echo "$SERVER_IP"; return; fi
  ip="$(curl -fsS4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsS4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsS4 --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null || true)"
  [ -n "$ip" ] || ip="YOUR_SERVER_IP"
  echo "$ip"
}

# ---------------------------------------------------------------------------
# 生成配置
# ---------------------------------------------------------------------------
build_config() {
  UUID="$(load_or_create_uuid)"
  XHTTP_PATH="$(load_or_create_path)"
  load_or_create_vlessenc

  PAD_LINE=""
  if [ -n "$XHTTP_PADDING" ]; then
    PAD_LINE=",
          \"xPaddingBytes\": \"$(json_escape "$XHTTP_PADDING")\""
  fi

  # flow 相关片段：为空时完全不出现在配置与链接里
  if [ -n "$FLOW" ]; then
    FLOW_FIELD=", \"flow\": \"$(json_escape "$FLOW")\""
    FLOW_PARAM="&flow=${FLOW}"
  else
    FLOW_FIELD=""
    FLOW_PARAM=""
  fi

  if [ "$MODE" = "reality" ]; then
    [ -n "$SNI" ] || die "reality 模式需要 SNI（伪装域名）"
    [ "$XRAY_PORT" = "443" ] || warn "Reality 监听在 $XRAY_PORT（非 443）更容易被识别"

    load_or_create_reality_keys
    SHORT_ID="$(load_or_create_short_id)"
    SERVER_IP="$(detect_public_ip)"
    [ -n "$DEST" ] || DEST="${SNI}:443"
    XHTTP_HOST="$SNI"

    cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}"${FLOW_FIELD} } ],
        "decryption": "$(json_escape "$DEKEY")"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$(json_escape "$DEST")",
          "xver": 0,
          "serverNames": [ "$(json_escape "$SNI")" ],
          "privateKey": "$(json_escape "$PRIVATE_KEY")",
          "shortIds": [ "${SHORT_ID}" ]
        },
        "xhttpSettings": {
          "host": "$(json_escape "$XHTTP_HOST")",
          "path": "$(json_escape "$XHTTP_PATH")",
          "mode": "${XHTTP_MODE}"${PAD_LINE}
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    CONNECT_HOST="$SERVER_IP"
    CONNECT_PORT="$XRAY_PORT"
    VLESS_NAME="${VLESS_NAME:-VLESS-XHTTP-REALITY}"
    VLESS_LINK="vless://${UUID}@${CONNECT_HOST}:${CONNECT_PORT}?encryption=${ENKEY}&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=$(uri_escape "$SNI")&fp=chrome&type=xhttp&mode=${XHTTP_MODE}${FLOW_PARAM}&path=$XHTTP_PATH&host=$(uri_escape "$XHTTP_HOST")#${VLESS_NAME}"

  else
    [ -n "$DOMAIN" ] || die "cdn 模式需要 DOMAIN"
    [ -f "$CERT_FILE" ] || die "证书不存在: $CERT_FILE"
    [ -f "$KEY_FILE" ]  || die "私钥不存在: $KEY_FILE"
    if command -v openssl >/dev/null 2>&1; then
      openssl x509 -in "$CERT_FILE" -noout -checkend 604800 >/dev/null 2>&1 \
        || warn "证书将在 7 天内过期或已过期"
    fi

    case "$CFPORT" in
      ""|443|2053|2083|2087|2096|8443) ;;
      *) warn "CFPORT=$CFPORT 不在 Cloudflare 官方 HTTPS 端口列表内" ;;
    esac

    CONNECT_HOST="${CFIP:-$DOMAIN}"
    CONNECT_PORT="${CFPORT:-443}"
    XHTTP_HOST="$DOMAIN"

    cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}"${FLOW_FIELD} } ],
        "decryption": "$(json_escape "$DEKEY")"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$(json_escape "$DOMAIN")",
          "alpn": ["h2"],
          "minVersion": "1.3",
          "certificates": [
            { "certificateFile": "${CERT_FILE}", "keyFile": "${KEY_FILE}" }
          ]
        },
        "xhttpSettings": {
          "host": "$(json_escape "$XHTTP_HOST")",
          "path": "$(json_escape "$XHTTP_PATH")",
          "mode": "${XHTTP_MODE}"${PAD_LINE}
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    VLESS_NAME="${VLESS_NAME:-VLESS-XHTTP-CDN}"
    VLESS_LINK="vless://${UUID}@${CONNECT_HOST}:${CONNECT_PORT}?encryption=${ENKEY}&security=tls&type=xhttp&mode=${XHTTP_MODE}${FLOW_PARAM}&path=$XHTTP_PATH&host=$(uri_escape "$DOMAIN")&sni=$(uri_escape "$DOMAIN")#${VLESS_NAME}"
  fi
}

# ---------------------------------------------------------------------------
# 配置自检
# ---------------------------------------------------------------------------
validate_config() {
  if ! "$XRAY_BIN" run -c config.json -test >/dev/null 2>&1; then
    warn "配置未通过校验："
    "$XRAY_BIN" run -c config.json -test 2>&1 | tail -20 >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 输出节点信息
# ---------------------------------------------------------------------------
print_info() {
  echo ""
  echo "=============== 节点信息 ==============="
  echo "模式      : $MODE"
  if [ "$MODE" = "reality" ]; then
    echo "地址      : ${CONNECT_HOST}:${CONNECT_PORT}"
    echo "SNI       : $SNI"
    echo "公钥      : $PUBLIC_KEY"
    echo "ShortID   : $SHORT_ID"
  else
    echo "域名      : $DOMAIN"
    echo "连接      : ${CONNECT_HOST}:${CONNECT_PORT}"
  fi
  echo "UUID      : $UUID"
  echo "Path      : $XHTTP_PATH"
  echo "加密组    : $XRAY_ENCRYPTION_GROUP"
  echo "Flow      : ${FLOW:-（未启用）}"
  echo ""
  echo "链接:"
  echo "$VLESS_LINK"
  echo "========================================"
  echo ""
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
detect_arch
download_xray
build_config
validate_config
print_info | tee "$WORKDIR/node.txt"

if [ "$DRY_RUN" = "true" ]; then
  info "DRY_RUN=true，仅输出配置，不启动"
  echo "--- config.json ---"
  cat config.json
  exit 0
fi

info "启动 Xray（MODE=$MODE, port=$XRAY_PORT）"
exec "$XRAY_BIN" run -c config.json
