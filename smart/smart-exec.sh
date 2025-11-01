#!/usr/bin/env bash
# ==========================================================
# 
# 功能：
#   ✅ 自动检测是否能访问 Google
#   ✅ 检测为国内环境时，为 https://raw.githubusercontent.com 添加加速前缀
#   ✅ 支持不加引号直接传入复杂命令 (&&, |, ; 等)
#   ✅ 首次执行时自动创建全局软链接 /usr/local/bin/smart-exec
# ==========================================================

PREFIX="https://speed.objboy.com/"
TIMEOUT=3
LINK_PATH="/usr/local/bin/smart-exec"

# -------- 组装完整命令（即使用户没加引号） --------
CMD="$*"
if [[ -z "$CMD" ]]; then
  echo "❌ 用法: $0 <命令>"
  echo "示例:"
  echo "  $0 wget -O init.sh https://raw.githubusercontent.com/... && chmod +x init.sh"
  echo ""
  echo "💡 提示: 该脚本支持自动为 GitHub 源添加加速前缀"
  exit 1
fi

# -------- 检查命令是否存在 --------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# -------- 检测是否能访问 Google --------
is_foreign() {
  if have_cmd curl && curl -s --head --max-time "$TIMEOUT" https://google.com >/dev/null 2>&1; then
    return 0
  fi
  if have_cmd wget && wget -q --spider --timeout="$TIMEOUT" https://google.com >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# -------- 自动创建软链接 --------
create_symlink() {
  local src_path
  src_path="$(realpath "$0" 2>/dev/null || echo "$0")"

  # 检查是否已存在
  if [[ -L "$LINK_PATH" || -f "$LINK_PATH" ]]; then
    return
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "⚙️  正在尝试创建全局软链接需要 root 权限。"
    if have_cmd sudo; then
      sudo ln -sf "$src_path" "$LINK_PATH" && echo "✅ 已创建软链接: $LINK_PATH"
    else
      echo "⚠️ 无法创建软链接（未安装 sudo）。请手动执行以下命令："
      echo "sudo ln -sf \"$src_path\" \"$LINK_PATH\""
    fi
  else
    ln -sf "$src_path" "$LINK_PATH" && echo "✅ 已创建软链接: $LINK_PATH"
  fi
}

# -------- 网络检测 --------
if is_foreign; then
  echo "🌍 检测到国外环境，直接执行原命令。"
else
  echo "🇨🇳 检测到国内环境，自动为 GitHub 源添加加速前缀。"
  CMD=$(echo "$CMD" | sed -E "s#https://raw\.githubusercontent\.com#${PREFIX}https://raw.githubusercontent.com#g")
fi

echo "--------------------------------------"
echo "▶️ 最终执行命令："
echo "$CMD"
echo "--------------------------------------"

# -------- 执行命令 --------
eval "$CMD"

# -------- 首次运行自动注册命令 --------
create_symlink
