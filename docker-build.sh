#!/usr/bin/env bash
# ARTEX Docker 本地构建 + 启动。
#
# 为什么需要这个脚本：原docker-compose.yml 拉的是上游 Docker Hub 镜像
# autumn27/artex，而该镜像仓库已被删除（拉取必然 404）。compose 现在改为
# 本地构建，但 Dockerfile 只装工具链、不在镜像内编译——它 COPY 的是
# **预编译好的** dist/<arch>/artex。所以完整链路是：
#
#   ① 前端静态导出 → server/webui/dist
#   ② 交叉编译当前平台的 Linux 二进制 → dist/<arch>/artex
#   ③ docker compose build（把该二进制放进镜像）
#   ④ docker compose up -d
#
# 直接 `docker compose up -d --build` 会跳过 ①② 并在 COPY 处失败。
#
# 用法：
#   ./docker-build.sh              # 构建并启动（amd64/arm64 按宿主机自动选）
#   ARTEX_UPDATE_REPO=owner/name ./docker-build.sh
#                                 # 同时注入一键更新发布源
#   ./docker-build.sh --rebuild    # 忽略缓存，从头重建镜像
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

info() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

REBUILD=0
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "未知参数：$arg（可用：--rebuild）" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "未检测到 docker"
docker compose version >/dev/null 2>&1 || die "未检测到 docker compose（v2）"
command -v go >/dev/null 2>&1 || die "未检测到 go（需要 Go 1.26.3+）"

# ── 宿主机架构 → compose 的 TARGETARCH ──────────────────────────
# Dockerfile: COPY dist/${TARGETARCH}/artex /app/artex
# buildx 默认注入宿主机架构，这里显式算出来是为了确认 ② 产出的目录名对得上。
HOST_ARCH="$(go env GOARCH)"
case "$HOST_ARCH" in
  amd64) TARGET_ARCH=amd64 ;;
  arm64) TARGET_ARCH=arm64 ;;
  *) die "未适配的架构：$HOST_ARCH（Dockerfile 需在 dist/<arch>/ 下有预编译二进制）" ;;
esac
ok "目标架构 linux/${TARGET_ARCH}"

# ── ① 前端静态导出 ────────────────────────────────────────────
if [ "${ARTEX_SKIP_FRONTEND:-0}" != "1" ]; then
  command -v npm >/dev/null 2>&1 || die "未检测到 npm（前端静态构建需要 Node.js/npm）"
  command -v rsync >/dev/null 2>&1 || die "未检测到 rsync"
  info "①/4 构建前端静态资源"
  [ -d web/node_modules ] || (cd web && npm ci)
  (cd web && npm run build:static)
  mkdir -p server/webui/dist
  rsync -a --delete web/out/ server/webui/dist/
else
  [ -d server/webui/dist ] || die "ARTEX_SKIP_FRONTEND=1 但 server/webui/dist 不存在"
  info "①/4 复用已有 server/webui/dist"
fi

# ── ② 交叉编译 Linux 二进制到 dist/<arch>/ ────────────────────
# 注意是 GOOS=linux：宿主机可能是 macOS，但镜像基础是 Debian，产物必须是 linux。
info "②/4 编译 linux/${TARGET_ARCH} 二进制"
mkdir -p "dist/${TARGET_ARCH}"
CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" \
  go build -tags embedui -trimpath \
  -ldflags "-s -w -buildid= -X main.version=${ARTEX_BUILD_VERSION:-local}$([ -n "${ARTEX_UPDATE_REPO:-}" ] && echo " -X github.com/Autumn-27/artex/selfupdate.Repo=${ARTEX_UPDATE_REPO}")" \
  -o "dist/${TARGET_ARCH}/artex" ./cmd/artex
ok "产物：dist/${TARGET_ARCH}/artex"

# ── ③ 构建镜像 ────────────────────────────────────────────────
if [ ! -f .env ]; then
  warn ".env 不存在，从 .env.example 复制一份"
  cp .env.example .env
  warn "已生成 .env——请务必修改其中的 POSTGRES_PASSWORD 后再启动"
fi
if grep -q '^POSTGRES_PASSWORD=change-me-please' .env; then
  die ".env 里POSTGRES_PASSWORD 仍是默认值，请先改掉再启动（这是数据库访问凭据）"
fi

BUILD_FLAG=()
[ "$REBUILD" = "1" ] && BUILD_FLAG=(--no-cache)
info "③/4 docker compose build artex"
ARTEX_TARGETARCH="$TARGET_ARCH" docker compose build "${BUILD_FLAG[@]}" artex

# ── ④ 启动 ────────────────────────────────────────────────────
info "④/4 docker compose up -d"
docker compose up -d
ok "完成→ http://localhost:8787 （首次进入 /setup 设置管理员密码）"
echo
info "查看日志： docker compose logs -f artex"
info "停止：     docker compose down"
info "换 LLM：   在页面「系统配置 → LLM 配置」里填，或写进 .env 后 docker compose up -d"