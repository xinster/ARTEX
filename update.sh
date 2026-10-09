#!/usr/bin/env bash
# ARTEX 更新脚本：① Docker 更新（拉新镜像重建）  ② 本地编译更新（重建二进制）
# 与 install.sh 对应：install 负责首次落地，update 负责升级到新版本。
# DB 迁移无需手动执行——artex 每次启动都会幂等重跑 schema.sql（含 ADD COLUMN/CREATE
# INDEX IF NOT EXISTS），所以“重启即迁移”。数据（pgdata 卷、./data、./skills）不受影响。
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

info(){ printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok(){   printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[!]\033[0m %s\n' "$*"; }
die(){  printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ask(){  local p="$1" d="${2:-}" a; read -rp "$p${d:+ [$d]}: " a; echo "${a:-$d}"; }

# ── 可选：同步仓库到最新代码（compose/脚本/本地编译源码都靠它更新）───────
sync_repo(){
  [ -d .git ] && command -v git >/dev/null 2>&1 || { warn "非 git 工作副本，跳过 git pull"; return; }
  [ "$(ask '拉取最新代码 (git pull --ff-only)? (y/n)' y)" = y ] || return
  if ! git pull --ff-only; then
    warn "git pull 未能快进（本地有改动或分支分叉）——请手动处理后重试，本次沿用当前代码"
  fi
}

# ── ① Docker 更新 ───────────────────────────────
update_docker(){
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
    || die "未检测到 docker / docker compose，请先用 ./install.sh 安装部署"
  [ -f .env ] || die "未找到 .env，请先运行 ./install.sh 完成首次部署"

  # 上游 Docker Hub 镜像 autumn27/artex 已删除，本 fork 的 compose 默认从源码本地构建，
  # 所以「更新镜像」= 重新构建，而不是 docker compose pull。只有当 .env 里显式设了
  # ARTEX_IMAGE（指向自己的 registry）时才走 pull 路径。
  if grep -q '^ARTEX_IMAGE=' .env 2>/dev/null; then
    local tag; tag="$(ask '目标镜像 tag（回车沿用 .env / latest）' '')"
    if [ -n "$tag" ]; then
      local img; img="$(grep '^ARTEX_IMAGE=' .env | head -1 | cut -d= -f2- | sed 's/:[^:]*$//')"
      if [ -n "$img" ]; then
        sed -i.bak "s|^ARTEX_IMAGE=.*|ARTEX_IMAGE=${img}:${tag}|" .env && rm -f .env.bak
        ok "已将 ARTEX_IMAGE 设为 ${img}:${tag}"
      fi
    fi
    info "拉取新镜像（仅 artex）…"
    docker compose pull artex
    docker compose up -d artex
  else
    info "未设 ARTEX_IMAGE → 走本地构建路径（上游镜像已删除）"
    [ -x ./docker-build.sh ] || die "缺少 ./docker-build.sh，请手动执行：前端导出 → go build → docker compose build"
    ./docker-build.sh --rebuild
  fi
  ok "更新完成 → http://localhost:8787"
  info "查看日志：docker compose logs -f artex"
  info "清理旧镜像（可选）：docker image prune -f"
}

# ── ② 本地编译更新 ──────────────────────────────
update_local(){
  command -v go >/dev/null 2>&1 || die "未检测到 Go（>=1.26）：https://go.dev/dl/"
  [ -f config.json ] || warn "未找到 config.json——若首次部署请改用 ./install.sh"
  ok "Go: $(go version)"

  if command -v npm >/dev/null 2>&1; then
    info "重建前端静态产物…"
    ( cd web && npm ci && npm run build:static )
    rm -rf server/webui/dist && cp -r web/out server/webui/dist
    info "重新编译内嵌单二进制…"
    CGO_ENABLED=0 go build -tags embedui -trimpath -o artex ./cmd/artex
  else
    warn "未检测到 npm：编译**不内嵌前端**的后端（前端需另跑 npm run dev）"
    CGO_ENABLED=0 go build -o artex ./cmd/artex
  fi
  ok "编译完成 → ./artex"
  warn "请重启正在运行的 artex 进程以生效（重启时会自动迁移 schema）"
}

echo "=============================="
echo "  ARTEX 更新"
echo "  1) Docker 更新（拉新镜像重建）"
echo "  2) 本地更新（go 重新编译）"
echo "=============================="
case "$(ask '选择' 1)" in
  1) sync_repo; update_docker ;;
  2) sync_repo; update_local ;;
  *) die "无效选择" ;;
esac
