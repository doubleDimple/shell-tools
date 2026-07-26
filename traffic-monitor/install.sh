#!/usr/bin/env bash
#===============================================================================
#  traffic-monitor 一键安装脚本
#  用法:
#    bash <(curl -fsSL https://raw.githubusercontent.com/doubleDimple/shell-tools/master/traffic-monitor/install.sh)
#===============================================================================
set -euo pipefail

# ---------- 可覆盖环境变量 ----------
GITHUB_REPO="${GITHUB_REPO:-doubleDimple/shell-tools}"
GITHUB_BRANCH="${GITHUB_BRANCH:-master}"
# 仓库内子目录（本工具在 shell-tools/traffic-monitor/）
GITHUB_SUBDIR="${GITHUB_SUBDIR:-traffic-monitor}"
INSTALL_DIR="${INSTALL_DIR:-/opt/traffic-monitor}"
RUN_SETUP="${RUN_SETUP:-true}"   # true=装完进入交互配置

c_green()  { printf '\033[0;32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m' "$*"; }
c_red()    { printf '\033[0;31m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }

info()  { echo "$(c_green "✓") $*"; }
warn()  { echo "$(c_yellow "!") $*"; }
err()   { echo "$(c_red "✗") $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

install_deps() {
  local missing=()
  need_cmd curl || missing+=(curl)
  need_cmd python3 || missing+=(python3)
  if ((${#missing[@]} == 0)); then
    info "依赖已满足: curl python3"
    return 0
  fi
  warn "缺少依赖: ${missing[*]}，尝试自动安装…"
  if need_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl python3 ca-certificates
  elif need_cmd dnf; then
    dnf install -y curl python3 ca-certificates
  elif need_cmd yum; then
    yum install -y curl python3 ca-certificates
  elif need_cmd apk; then
    apk add --no-cache curl python3 ca-certificates
  else
    err "请先手动安装: ${missing[*]}"
    exit 1
  fi
  info "依赖安装完成"
}

raw_base() {
  local sub="${GITHUB_SUBDIR}"
  if [[ -n "$sub" ]]; then
    echo "https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/${sub}"
  else
    echo "https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"
  fi
}

download_files() {
  local base
  base="$(raw_base)"
  local files=(traffic-monitor.sh config.conf.example README.md)

  echo ""
  echo "$(c_bold "安装目录: ${INSTALL_DIR}")"
  echo "$(c_bold "来源:     ${GITHUB_REPO}@${GITHUB_BRANCH}/${GITHUB_SUBDIR}")"
  mkdir -p "$INSTALL_DIR"
  mkdir -p "${INSTALL_DIR}/state"

  local f url
  for f in "${files[@]}"; do
    url="${base}/${f}"
    echo "  下载 ${f} …"
    if ! curl -fsSL --retry 3 --retry-delay 1 "$url" -o "${INSTALL_DIR}/${f}.tmp"; then
      err "下载失败: $url"
      err "请确认仓库已公开，且路径/分支正确"
      rm -f "${INSTALL_DIR}/${f}.tmp"
      exit 1
    fi
    mv "${INSTALL_DIR}/${f}.tmp" "${INSTALL_DIR}/${f}"
  done

  chmod +x "${INSTALL_DIR}/traffic-monitor.sh"
  # 保留已有 config.conf，不覆盖
  if [[ ! -f "${INSTALL_DIR}/config.conf" && -f "${INSTALL_DIR}/config.conf.example" ]]; then
    cp "${INSTALL_DIR}/config.conf.example" "${INSTALL_DIR}/config.conf"
    chmod 600 "${INSTALL_DIR}/config.conf"
    info "已生成默认 config.conf（可在向导中修改）"
  else
    info "保留已有 config.conf（若已存在）"
  fi
}

link_bin() {
  local target="/usr/local/bin/traffic-monitor"
  if [[ -w /usr/local/bin ]] || [[ "$(id -u)" -eq 0 ]]; then
    ln -sfn "${INSTALL_DIR}/traffic-monitor.sh" "$target"
    info "已链接命令: traffic-monitor  →  ${INSTALL_DIR}/traffic-monitor.sh"
  else
    warn "无权限写入 /usr/local/bin，跳过全局命令"
    echo "  可手动执行: ${INSTALL_DIR}/traffic-monitor.sh"
  fi
}

run_setup() {
  if [[ "$RUN_SETUP" != "true" ]]; then
    warn "跳过交互配置 (RUN_SETUP=false)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    warn "当前非交互终端，跳过向导。请稍后执行:"
    echo "  ${INSTALL_DIR}/traffic-monitor.sh --setup"
    return 0
  fi
  echo ""
  echo "$(c_bold "════════ 开始交互配置 ════════")"
  bash "${INSTALL_DIR}/traffic-monitor.sh" --setup
}

main() {
  echo ""
  echo "$(c_bold "╔══════════════════════════════════════╗")"
  echo "$(c_bold "║   Traffic Monitor 一键安装           ║")"
  echo "$(c_bold "╚══════════════════════════════════════╝")"

  if [[ "$(id -u)" -ne 0 ]]; then
    warn "建议使用 root 安装到 ${INSTALL_DIR}（当前用户: $(id -un)）"
  fi

  install_deps
  download_files
  link_bin
  run_setup

  echo ""
  echo "$(c_green "✓") 安装完成"
  echo "  目录:   ${INSTALL_DIR}"
  echo "  启动:   ${INSTALL_DIR}/traffic-monitor.sh"
  echo "  菜单:   ${INSTALL_DIR}/traffic-monitor.sh"
  echo "  配置:   ${INSTALL_DIR}/traffic-monitor.sh --setup"
  echo "  状态:   ${INSTALL_DIR}/traffic-monitor.sh --status"
  echo "  守护:   ${INSTALL_DIR}/traffic-monitor.sh --start"
  echo ""
}

main "$@"
