# x-cf

VLESS + XHTTP 节点镜像（REALITY / TLS-CDN 双模式），**完全由环境变量控制**，GitHub Actions 自动构建公开镜像。

- 镜像地址：`ghcr.io/<ly921002>/x-cf:latest`
- 架构：`linux/amd64` + `linux/arm64`
- Xray 在**容器启动时**下载并校验（不预置在镜像里，镜像约 20 MB，每次启动都能拿到最新版）

---

## 快速开始

### Reality 模式（推荐，免证书）

```bash
docker run -d \
  --name x-cf \
  --restart unless-stopped \
  --network host \
  -e MODE=reality \
  -e SNI=www.apple.com \
  -e XRAY_PORT=443 \
  -v "$PWD/xcf-data:/data" \
  ghcr.io/ly921002/x-cf:latest

docker logs x-cf | grep -A2 '链接'
```

### CDN 模式（走 Cloudflare）

```bash
docker run -d \
  --name x-cf \
  --restart unless-stopped \
  --network host \
  -e MODE=cdn \
  -e DOMAIN=example.com \
  -e XRAY_PORT=8443 \
  -e CFPORT=443 \
  -v "$PWD/cert:/cert:ro" \
  -v "$PWD/xcf-data:/data" \
  ghcr.io/ly921002/x-cf:latest
```

---

## 环境变量

### 核心

| 变量 | 默认 | 说明 |
|---|---|---|
| `MODE` | `reality` | `reality` 或 `cdn` |
| `XRAY_PORT` | `443` | 容器内 Xray 监听端口 |
| `XRAY_VERSION` | `latest` | `latest` 或固定版本（如 `v26.10.31`） |
| `XRAY_FORCE_UPDATE` | `false` | `true` 时忽略缓存强制重下 |
| `XRAY_DOWNLOAD_BASE` | 官方 GitHub | 换源（如国内镜像加速） |
| `DRY_RUN` | `false` | `true` 只打印配置和链接，不启动 |

### Reality 模式

| 变量 | 默认 | 说明 |
|---|---|---|
| `SNI` | 无（**必填**） | 伪装域名，需支持 TLS1.3 + h2 |
| `SERVER_IP` | 自动探测 | 节点地址 |
| `DEST` | `${SNI}:443` | 回落目标 |
| `SHORT_ID` | 随机 | 自定义 shortId |
| `PRIVATE_KEY` | 随机 | 自定义私钥，会自动推导公钥 |

### CDN 模式

| 变量 | 默认 | 说明 |
|---|---|---|
| `DOMAIN` | 无（**必填**） | 你的域名 |
| `CERT_FILE` | `/cert/cert.pem` | 证书路径 |
| `KEY_FILE` | `/cert/key.key` | 私钥路径 |
| `CFIP` | 空 | 客户端连接的优选 IP（留空用 DOMAIN） |
| `CFPORT` | `443` | 客户端连接的 CF 端口 |

### 通用

| 变量 | 默认 | 说明 |
|---|---|---|
| `UUID` | 随机 | 自定义 UUID |
| `XHTTP_PATH` | 随机 | 自定义完整 path |
| `XHTTP_PATH_BASE` | `/api/v1` | 路径前缀 |
| `XHTTP_PATH_LEN` | `8` | 随机段长度，`0` 表示只用 BASE |
| `XHTTP_MODE` | `auto` | `auto` / `packet-up` / `stream-up` / `stream-one` |
| `XHTTP_PADDING` | `100-1000` | 填充范围，留空关闭 |
| `XRAY_ENCRYPTION_GROUP` | `pq` | `pq`（ML-KEM，链接约 1800 字符）或 `x25519`（链接约 200 字符） |
| `VLESS_NAME` | 按模式 | 链接备注名 |
| `WORKDIR` | `/data` | 凭据与二进制缓存目录 |

---

## 凭据持久化

所有凭据（UUID / path / Reality 密钥 / shortId）和下载的 Xray 都存 `/data`。挂载后重建容器不会失效、不会重复下载。

```bash
-v "$PWD/xcf-data:/data"
```

> **务必挂载**，否则 `docker run` 重建一次，所有已分发的节点全部失效。

备份就是复制这个目录。

---

## 自己构建

### GitHub 自动构建

推到 GitHub 后，`.github/workflows/docker.yml` 会自动：

1. 构建 `linux/amd64` + `linux/arm64` 多架构镜像
2. 推送到 GHCR（`ghcr.io/<owner>/<repo>:latest`）
3. 跑冒烟测试（DRY_RUN 生成配置 + 断言关键字段）

首次推送后需要把包设为公开：
`仓库 → Packages → x-cf → Package settings → Change visibility → Public`

### 本地构建

```bash
docker build -t x-cf:local .
docker run --rm -e MODE=reality -e SNI=www.apple.com -e DRY_RUN=true -v "$PWD/t:/data" x-cf:local
```

---

## 查看节点链接

链接在容器启动时打印，同时写入 `/data/node.txt`：

```bash
docker logs x-cf | grep vless://
# 或
cat xcf-data/node.txt
```

---

## 常见问题

**Q: 443 端口起不来？**
`network host` 模式下需要有权限绑定 443。换 `XRAY_PORT=8443`（Reality 在非 443 上隐蔽性会下降）。

**Q: 下载 Xray 失败？**
镜像基于 GitHub Releases，国内可能超时。设置 `XRAY_DOWNLOAD_BASE` 指向可用的镜像源。

**Q: 链接太长，二维码扫不出来？**
`-e XRAY_ENCRYPTION_GROUP=x25519`。切换后记得清掉旧缓存（或设 `XRAY_FORCE_UPDATE=true` 并删除 `/data/enc_*.txt`）。

**Q: 报「缺少可执行权限」？**
`/data` 落在不支持 POSIX 权限的文件系统（NTFS / 部分 NAS）。换到 ext4/xfs 本地卷。

**Q: 怎么升级 Xray？**
`docker restart x-cf` 即可——每次启动会检查最新版本。想强制重下：`-e XRAY_FORCE_UPDATE=true`。

---

## 安全说明

- Xray 从**官方 GitHub Releases** 下载，并用官方 `.dgst` 的 SHA256 校验，校验失败直接退出。
- 生成的配置先跑 `xray run -c config.json -test`，非法配置不启动。
- 镜像通过 GitHub Actions 构建，带 provenance 与 SBOM。
- 凭据只存在本机 `/data`，不联网同步。
