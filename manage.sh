#!/usr/bin/env bash
# ============================================================
# Sub-Store 管理面板
#   substore            进入交互菜单
#   substore install    安装 / 重新部署
#   substore update     更新到最新版
#   substore restart    重启
#   substore uninstall  卸载
#   substore status     查看状态与地址
#   substore logs       实时日志
#   substore cors       设置前端来源白名单（解决 403 CORS 报错）
#   substore setup      安装本命令到 /usr/local/bin/substore
# 环境变量: SUBSTORE_PORT(默认3001) SUBSTORE_DIR(默认/opt/sub-store)
# ============================================================
set -uo pipefail

DIR="${SUBSTORE_DIR:-/opt/sub-store}"
NAME="${SUBSTORE_NAME:-sub-store}"
IMAGE="${SUBSTORE_IMAGE:-xream/sub-store:latest}"
SELF_TARGET="/usr/local/bin/substore"
COMPOSE="$DIR/docker-compose.yml"
# 远程安装/管道运行时用于下载脚本本体；install.sh 会把它改写成实际可用的地址
DEFAULT_RAW_BASE="https://cdn.jsdelivr.net/gh/a1195992737/sub-store-manager@main"
DEFAULT_RAW_FALLBACK="https://raw.githubusercontent.com/a1195992737/sub-store-manager/main"

C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_Y=$'\033[1;33m'
C_B=$'\033[1;36m'; C_D=$'\033[2m'; C_N=$'\033[0m'

ok()   { printf "  ${C_G}✔${C_N} %s\n" "$*"; }
bad()  { printf "  ${C_R}✘${C_N} %s\n" "$*"; }
warn() { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
info() { printf "  ${C_D}·${C_N} %s\n" "$*"; }
line() { printf "${C_B}%s${C_N}\n" "────────────────────────────────────────────────────"; }

# ---------- 基础 ----------
# 返回脚本本体的真实路径；用 curl | bash 管道执行时 $0 是 "bash"，此时返回失败
self_file() {
  local f="${BASH_SOURCE[0]:-$0}"
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
  readlink -f "$f" 2>/dev/null || printf '%s' "$f"
}

# 从仓库下载脚本本体，成功时 stdout 输出实际用到的 base 地址
download_self() {
  local out="$1" base
  for base in "$DEFAULT_RAW_BASE" "${DEFAULT_RAW_FALLBACK:-}"; do
    [ -n "$base" ] || continue
    if curl -fsSL --max-time 30 "${base}/manage.sh" -o "$out" 2>/dev/null \
       && [ -s "$out" ] && head -1 "$out" | grep -q '^#!'; then
      printf '%s' "$base"
      return 0
    fi
  done
  return 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  command -v sudo >/dev/null 2>&1 || { bad "需要 root 权限，且系统未安装 sudo"; exit 1; }
  local f
  if f="$(self_file)"; then
    exec sudo -E bash "$f" "$@"
  fi
  # 管道方式执行且当前不是 root：先把本体落盘，再提权执行
  f="$(mktemp /tmp/substore-XXXXXX.sh)"
  if download_self "$f" >/dev/null; then
    exec sudo -E bash "$f" "$@"
  fi
  rm -f "$f"
  bad "无法获取脚本本体，请改用: sudo bash 你的脚本路径"
  exit 1
}

dc() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE" --project-directory "$DIR" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE" "$@"
  else
    bad "未找到 docker compose，请先执行 substore install"
    return 1
  fi
}

installed() { [ -f "$COMPOSE" ]; }

get_prefix() {
  local p
  p="$(cat "$DIR/.backend-path" 2>/dev/null || true)"
  if [ -z "$p" ]; then
    p="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null \
         | sed -n 's|^SUB_STORE_FRONTEND_BACKEND_PATH=||p' | head -1)"
  fi
  printf '%s' "$p"
}

get_port() {
  local p=""
  if [ -f "$COMPOSE" ]; then
    # 兼容 "3001:3000" 与 "127.0.0.1:3001:3000" 两种写法
    p="$(grep -oE '[0-9]+:3000\b' "$COMPOSE" | head -1)"
    p="${p%%:3000}"
    p="${p##*:}"
  fi
  printf '%s' "${p:-${SUBSTORE_PORT:-3001}}"
}

get_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
  printf '%s' "${ip:-<服务器IP>}"
}

get_version() {
  local port prefix v
  port="$(get_port)"; prefix="$(get_prefix)"
  [ -n "$prefix" ] || return 0
  v="$(curl -fsS --max-time 3 "http://127.0.0.1:${port}${prefix}/api/utils/env" 2>/dev/null \
       | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  printf '%s' "$v"
}

cstate() {
  docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo "missing"
}

wait_healthy() {
  local port prefix i code
  port="$(get_port)"; prefix="$(get_prefix)"
  for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null)"
    [ "$code" = "200" ] && { ok "健康检查通过（HTTP 200）"; return 0; }
    sleep 1
  done
  bad "健康检查未通过，容器内可能还在初始化"
  warn "查看日志: substore logs"
  return 1
}

# ---------- 安装 Docker ----------
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  warn "未检测到 Docker + Compose 插件，开始安装"
  . /etc/os-release 2>/dev/null || true
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl >/dev/null

  local conflicts installed_pkgs
  conflicts="docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc"
  installed_pkgs="$(dpkg-query -W -f='${Package}\n' $conflicts 2>/dev/null || true)"
  if [ -n "$installed_pkgs" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq $installed_pkgs >/dev/null
    info "已移除冲突包: $(echo $installed_pkgs | tr '\n' ' ')"
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || {
    bad "下载 Docker GPG 密钥失败，检查网络"; return 1; }
  chmod a+r /etc/apt/keyrings/docker.asc   # Debian 13 用 sqv 校验，必须可读

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME:-trixie}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update -qq || { bad "APT 更新失败"; return 1; }
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null || {
    bad "Docker 安装失败"; return 1; }
  systemctl enable --now docker >/dev/null 2>&1 || true
  systemctl is-active --quiet docker || { bad "Docker 服务未启动"; return 1; }
  ok "Docker 安装完成: $(docker --version)"
}

# ---------- 各功能 ----------
do_install() {
  line; echo -e " ${C_B}安装 / 重新部署 Sub-Store${C_N}"; line
  if installed; then
    warn "检测到已存在的配置: $COMPOSE"
    read -r -p "  覆盖配置并重新部署？(数据不会删除) [y/N] " a
    case "$a" in [yY]*) ;; *) info "已取消"; return 0 ;; esac
  fi
  ensure_docker || return 1

  local port prefix
  port="${SUBSTORE_PORT:-$(get_port)}"

  if [ -f "$DIR/.backend-path" ]; then
    prefix="$(cat "$DIR/.backend-path")"
    info "复用已有后端路径: ${prefix}"
  else
    prefix="/$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    info "生成后端路径: ${prefix}"
  fi
  mkdir -p "$DIR/data"
  printf '%s' "$prefix" > "$DIR/.backend-path"
  chmod 600 "$DIR/.backend-path"
  [ -f "$COMPOSE" ] && cp "$COMPOSE" "$COMPOSE.bak.$(date +%s)"

  cat > "$COMPOSE" <<EOF
services:
  sub-store:
    image: ${IMAGE}
    container_name: ${NAME}
    restart: always
    ports:
      # MERGE 模式下前后端都在容器内 3000 端口
      - "${port}:3000"
    environment:
      - SUB_STORE_FRONTEND_BACKEND_PATH=${prefix}
      - SUB_STORE_BACKEND_MERGE=true
      - TZ=Asia/Shanghai
    volumes:
      - ${DIR}/data:/opt/app/data
EOF

  info "拉取镜像 ${IMAGE}"
  dc pull -q || { bad "镜像拉取失败"; return 1; }
  dc up -d || { bad "容器启动失败"; return 1; }
  sleep 2
  wait_healthy
  do_status
}

do_update() {
  line; echo -e " ${C_B}更新 Sub-Store${C_N}"; line
  installed || { bad "尚未安装，请先执行 substore install"; return 1; }
  ensure_docker || return 1
  local before after
  before="$(get_version)"
  info "当前版本: ${before:-未知}"
  info "拉取最新镜像…"
  dc pull -q || { bad "拉取失败，检查网络或镜像源"; return 1; }
  dc up -d || { bad "重启失败"; return 1; }
  sleep 2
  wait_healthy
  after="$(get_version)"
  ok "更新完成: ${before:-?} → ${after:-?}"
  info "清理旧镜像: docker image prune -f"
}

do_restart() {
  line; echo -e " ${C_B}重启 Sub-Store${C_N}"; line
  installed || { bad "尚未安装，请先执行 substore install"; return 1; }
  dc restart || { bad "重启失败"; return 1; }
  sleep 2
  wait_healthy
}

do_status() {
  line; echo -e " ${C_B}Sub-Store 状态${C_N}"; line
  if ! installed && [ "$(cstate)" = "missing" ]; then
    warn "未安装"; return 0
  fi
  local st port prefix ip ver
  st="$(cstate)"; port="$(get_port)"; prefix="$(get_prefix)"; ip="$(get_ip)"; ver="$(get_version)"
  case "$st" in
    running) ok "运行状态: 运行中 (running)" ;;
    missing) bad "运行状态: 容器不存在" ;;
    *)       bad "运行状态: ${st}" ;;
  esac
  [ -n "$ver" ] && info "后端版本: ${ver}"
  info "前端地址: http://${ip}:${port}/"
  [ -n "$prefix" ] && info "后端地址: http://${ip}:${port}${prefix}"
  info "数据目录: ${DIR}/data"
  info "配置文件: ${COMPOSE}"
  if [ "$st" = "running" ]; then
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/" 2>/dev/null)"
    [ "$code" = "200" ] && ok "本地访问: 200 正常" || bad "本地访问: ${code:-无响应}"
  fi
}

do_logs() {
  docker logs -f --tail 100 "$NAME"
}

get_cors() {
  local v=""
  if [ -f "$COMPOSE" ]; then
    v="$(sed -n 's/^[^#]*SUB_STORE_CORS_ALLOWED_ORIGINS=\([^"]*\).*/\1/p' "$COMPOSE" | head -1)"
  fi
  if [ -z "$v" ]; then
    v="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null \
         | sed -n 's/^SUB_STORE_CORS_ALLOWED_ORIGINS=//p' | head -1)"
  fi
  printf '%s' "$v"
}

# 当浏览器里前端域名与后端白名单不匹配时，后端会返回 403 CORS origin not allowed
do_cors() {
  line; echo -e " ${C_B}设置前端来源白名单 (CORS)${C_N}"; line
  installed || { bad "尚未安装，请先执行 substore install"; return 1; }
  ensure_docker || return 1

  local cur port prefix origin newlist code i
  cur="$(get_cors)"
  port="$(get_port)"; prefix="$(get_prefix)"

  if [ -n "$cur" ]; then
    info "当前白名单: ${cur}"
  else
    info "当前白名单: 未设置（后端使用默认值）"
    info "默认值: https://sub-store.vercel.app,http://substore.stash,https://substore.stash"
  fi

  echo
  echo -e "  ${C_D}填你在浏览器地址栏里打开前端时的完整来源，必须带协议，端口也要写：${C_N}"
  echo -e "  ${C_D}  https://sub.example.com        http://1.2.3.4:5173${C_N}"
  echo -e "  ${C_D}  输入 reset 恢复默认  输入 * 放行所有来源（不推荐）${C_N}"
  read -r -p "  前端来源: " origin
  origin="$(printf '%s' "$origin" | tr -d '[:space:]')"
  [ -n "$origin" ] || { info "未输入，已取消"; return 0; }

  case "$origin" in
    reset)
      newlist="https://sub-store.vercel.app,http://substore.stash,https://substore.stash" ;;
    '*')
      warn "放行所有来源，任何网站都能读写你的后端，仅靠随机前缀兜底"
      newlist="*" ;;
    http://*|https://*)
      newlist="${origin%/}"
      case ",${cur}," in
        *",${newlist},"*) info "该来源已在白名单中，仍将重写以确保生效" ;;
        *) [ -n "$cur" ] && newlist="${cur},${newlist}" && info "已追加到现有白名单" ;;
      esac
      ;;
    *)
      bad "格式不对，必须以 http:// 或 https:// 开头（不要带路径）"
      return 1 ;;
  esac

  # 写入 compose（同时处理被注释掉的行）
  if grep -q 'SUB_STORE_CORS_ALLOWED_ORIGINS' "$COMPOSE"; then
    sed -i "s#^.*SUB_STORE_CORS_ALLOWED_ORIGINS=.*#      - SUB_STORE_CORS_ALLOWED_ORIGINS=${newlist}#" "$COMPOSE"
  else
    sed -i "/SUB_STORE_BACKEND_MERGE/a\\      - SUB_STORE_CORS_ALLOWED_ORIGINS=${newlist}" "$COMPOSE"
  fi
  grep -n 'CORS_ALLOWED_ORIGINS' "$COMPOSE" | sed 's/^/     /'

  info "重建容器以生效…"
  dc up -d >/dev/null || { bad "容器重建失败"; return 1; }

  # 用 Origin 头实测，403 说明仍未被放行
  for i in $(seq 1 20); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
      -H "Origin: ${origin}" "http://127.0.0.1:${port}${prefix}/api/utils/env" 2>/dev/null)"
    [ "$code" = "200" ] && break
    sleep 1
  done

  echo
  if [ "$code" = "200" ]; then
    ok "验证通过：带着 Origin: ${origin} 请求后端返回 200"
    info "现在去浏览器强制刷新前端页面（Ctrl+Shift+R）"
  elif [ "$code" = "403" ]; then
    bad "仍然 403：白名单没包含 ${origin}"
    warn "确认你填的和地址栏里显示的完全一致（协议、域名、端口都要对上）"
    warn "例如前端是 http://1.2.3.4:5173，写成 https 或不带端口都会失败"
  else
    warn "验证返回 HTTP ${code}，可用 substore logs 看后端日志"
  fi
}

do_uninstall() {
  line; echo -e " ${C_R}卸载 Sub-Store${C_N}"; line
  if ! installed && [ "$(cstate)" = "missing" ]; then
    warn "未安装"; return 0
  fi
  printf "  ${C_Y}即将停止并删除容器${C_N}，数据目录 ${DIR}/data 默认会保留\n"
  read -r -p "  确认卸载？[y/N] " a
  case "$a" in [yY]*) ;; *) info "已取消"; return 0 ;; esac

  dc down 2>/dev/null || docker rm -f "$NAME" >/dev/null 2>&1 || true
  ok "容器已移除"

  printf "\n"
  printf "  ${C_R}⚠️  此操作非常危险，可能导致不可逆的数据丢失！${C_N}\n"
  printf "  彻底删除会移除 ${DIR}/data 里所有订阅、脚本、配置，且无法恢复。\n"
  read -r -p "  是否彻底删除数据目录与容器配置？输入 yes 确认: " a2
  if [ "$a2" = "yes" ]; then
    rm -rf "$DIR"
    ok "已删除 ${DIR}"
    read -r -p "  同时删除镜像 ${IMAGE}？[y/N] " a3
    case "$a3" in
      [yY]*) docker rmi "$IMAGE" >/dev/null 2>&1 && ok "镜像已删除" || warn "镜像删除失败（可能被其他容器占用）" ;;
    esac
  else
    info "数据已保留在 ${DIR}/data，重装时会自动复用"
  fi
}

do_setup() {
  line; echo -e " ${C_B}安装快捷命令${C_N}"; line
  local src tmp base
  if src="$(self_file)"; then
    if [ "$src" = "$SELF_TARGET" ]; then
      ok "快捷命令已安装: substore"; return 0
    fi
    install -m 0755 "$src" "$SELF_TARGET" || { bad "写入 ${SELF_TARGET} 失败"; return 1; }
  else
    info "检测到管道方式运行，下载脚本本体…"
    tmp="$(mktemp /tmp/substore-XXXXXX.sh)"
    if base="$(download_self "$tmp")"; then
      install -m 0755 "$tmp" "$SELF_TARGET" || { rm -f "$tmp"; bad "写入 ${SELF_TARGET} 失败"; return 1; }
      # 记住实际可用的下载地址，方便以后再次安装时不依赖占位符
      sed -i "s|^DEFAULT_RAW_BASE=.*|DEFAULT_RAW_BASE=\"${base}\"|" "$SELF_TARGET"
      rm -f "$tmp"
    else
      rm -f "$tmp"
      bad "下载脚本失败，请手动上传 manage.sh 后执行"
      return 1
    fi
  fi
  ok "已安装: ${SELF_TARGET}"
  info "以后任意目录直接输入: ${C_G}substore${C_N}"
}

# ---------- 菜单 ----------
draw_menu() {
  clear 2>/dev/null || true
  local st port prefix ip ver
  st="$(cstate)"; port="$(get_port)"; prefix="$(get_prefix)"; ip="$(get_ip)"; ver="$(get_version)"
  echo -e "${C_B}  ╭──────────────────────────────────────────────╮${C_N}"
  echo -e "${C_B}  │${C_N}        ${C_G}Sub-Store${C_N}  管理面板                   ${C_B}│${C_N}"
  echo -e "${C_B}  ╰──────────────────────────────────────────────╯${C_N}"
  echo
  case "$st" in
    running) echo -e "   状态   ${C_G}● 运行中${C_N}  ${C_D}${ver}${C_N}" ;;
    missing) echo -e "   状态   ${C_D}○ 未安装${C_N}" ;;
    *)       echo -e "   状态   ${C_R}○ ${st}${C_N}" ;;
  esac
  [ "$st" = "running" ] && {
    echo -e "   前端   http://${ip}:${port}/"
    echo -e "   后端   http://${ip}:${port}${prefix}"
  }
  echo -e "   目录   ${C_D}${DIR}${C_N}"
  echo
  line
  echo -e "   ${C_G}1${C_N}) 安装 / 重新部署"
  echo -e "   ${C_G}2${C_N}) 更新到最新版"
  echo -e "   ${C_G}3${C_N}) 重启服务"
  echo -e "   ${C_G}4${C_N}) 卸载"
  echo -e "   ${C_G}5${C_N}) 查看状态与地址"
  echo -e "   ${C_G}6${C_N}) 实时日志    ${C_D}(Ctrl+C 返回)${C_N}"
  echo -e "   ${C_G}7${C_N}) 前端域名设置 ${C_D}(解决 403 CORS 报错)${C_N}"
  if [ "$(self_file 2>/dev/null || true)" != "$(readlink -f "$SELF_TARGET" 2>/dev/null)" ]; then
    echo -e "   ${C_G}8${C_N}) 安装快捷命令 ${C_D}(substore)${C_N}"
  fi
  echo -e "   ${C_D}0) 退出${C_N}"
  line
}

menu() {
  local c
  while true; do
    draw_menu
    read -r -p "  请选择: " c || exit 0
    case "$c" in
      1) do_install ;;
      2) do_update ;;
      3) do_restart ;;
      4) do_uninstall ;;
      5) do_status ;;
      6) do_logs ;;
      7) do_cors ;;
      8) do_setup ;;
      0|q|quit) exit 0 ;;
      *) warn "无效选项: $c" ;;
    esac
    echo
    read -r -p "  按回车返回菜单…" _ || exit 0
  done
}

# ---------- 入口 ----------
case "${1:-menu}" in
  menu)            need_root menu; menu ;;
  install)         need_root install; do_install ;;
  update|upgrade)  need_root update; do_update ;;
  restart)         need_root restart; do_restart ;;
  uninstall|rm)    need_root uninstall; do_uninstall ;;
  status|info)     need_root status; do_status ;;
  logs)            need_root logs; do_logs ;;
  cors)            need_root cors; do_cors ;;
  setup)           need_root setup; do_setup ;;
  -h|--help|help)
    if f="$(self_file)"; then
      sed -n '2,14p' "$f" | sed 's/^# \{0,1\}//'
    else
      echo "substore [menu|install|update|restart|uninstall|status|logs|cors|setup]"
    fi
    ;;
  *) bad "未知命令: $1"; info "可用: menu install update restart uninstall status logs cors setup"; exit 1 ;;
esac
