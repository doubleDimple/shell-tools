#!/usr/bin/env bash
# 智能执行脚本 (终极版)
# 功能：
#   - 自动检测是否能访问 Google
#   - 若检测为国内环境，则为所有 https://raw.githubusercontent.com 添加加速前缀
#   - 支持不加引号直接传入复杂命令 (&&, |, ; 等都能处理)

PREFIX="https://speed.objboy.com/"
TIMEOUT=3

# -------- 组装完整命令（即使用户没加引号） --------
CMD="$*"
if [[ -z "$CMD" ]]; then
  echo "❌ 用法: $0 <命令>"
  echo "示例:"
  echo "  $0 wget -O init.sh https://raw.githubusercontent.com/... && chmod +x init.sh"
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
