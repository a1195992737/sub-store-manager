#!/usr/bin/env bash
# ============================================================
# Sub-Store 管理面板 · 一键安装脚本
#
# 用法（任选其一）:
#   curl -fsSL https://cdn.jsdelivr.net/gh/YOURNAME/sub-store-manager@main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/YOURNAME/sub-store-manager/main/install.sh | sudo bash
#
# 安装后即可使用命令: substore
# ============================================================
set -uo pipefail

# 下载源（按顺序尝试）：国内优先 jsDelivr，其次 GitHub raw
RAW_BASE="${SUBSTORE_RAW_BASE:-https://cdn.jsdelivr.net/gh/YOURNAME/sub-store-manager@main}"
RAW_FALLBACK="${SUBSTORE_RAW_FALLBACK:-https://raw.githubusercontent.com/YOURNAME/sub-store-manager/main}"
TARGET="/usr/local/bin/substore"

C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_Y=$'\033[1;33m'
C_B=$'\033[1;36m'; C_D=$'\033[2m'; C_N=$'\033[0m'
ok()   { printf "  ${C_G}✔${C_N} %s\n" "$*"; }
bad()  { printf "  ${C_R}✘${C_N} %s\n" "$*"; }
info() { printf "  ${C_D}·${C_N} %s\n" "$*"; }

printf "${C_B}Sub-Store 管理面板 · 安装${C_N}\n"

# ---------- 环境检查 ----------
[ "$(id -u)" -eq 0 ] || { bad "需要 root 权限，请用: curl -fsSL <url> | sudo bash"; exit 1; }

if ! command -v curl >/dev/null 2>&1; then
  info "未检测到 curl，正在安装"
  command -v apt-get >/dev/null 2>&1 && apt-get update -qq && apt-get install -y -qq curl >/dev/null || {
    bad "请先安装 curl 再重试"; exit 1; }
fi

# ---------- 下载 ----------
TMP="$(mktemp /tmp/substore-install-XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

USED_BASE=""
for base in "$RAW_BASE" "$RAW_FALLBACK"; do
  [ -n "$base" ] || continue
  info "下载: ${base}/manage.sh"
  if curl -fsSL --max-time 40 "${base}/manage.sh" -o "$TMP" 2>/dev/null \
     && [ -s "$TMP" ] && head -1 "$TMP" | grep -q '^#!'; then
    USED_BASE="$base"
    break
  fi
  bad "该源不可用，尝试下一个"
done

if [ -z "$USED_BASE" ]; then
  bad "所有下载源都失败了"
  info "可手动下载 manage.sh 后执行: sudo bash manage.sh setup"
  exit 1
fi
ok "下载完成（来源: ${USED_BASE}）"

# ---------- 安装 ----------
install -m 0755 "$TMP" "$TARGET" || { bad "写入 ${TARGET} 失败"; exit 1; }
# 记住实际可用的源，方便脚本以后自己重新下载（例如通过管道方式 setup）
sed -i "s|^DEFAULT_RAW_BASE=.*|DEFAULT_RAW_BASE=\"${USED_BASE}\"|" "$TARGET"

bash -n "$TARGET" || { bad "脚本校验失败，可能下载不完整"; rm -f "$TARGET"; exit 1; }
ok "已安装到 ${TARGET}"

# ---------- 收尾 ----------
printf '\n'
printf "  ${C_G}安装完成${C_N}\n"
printf "  ${C_D}直接输入下面的命令开始使用：${C_N}\n\n"
printf "      ${C_G}substore${C_N}\n\n"
printf "  ${C_D}常用子命令：${C_N}\n"
printf "      substore install    安装/重新部署 Sub-Store\n"
printf "      substore update     更新到最新版\n"
printf "      substore status     查看地址与状态\n"
printf "      substore cors       解决前端 403 CORS 报错\n"
printf '\n'
