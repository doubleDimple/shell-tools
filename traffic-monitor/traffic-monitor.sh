#!/usr/bin/env bash
#===============================================================================
#  流量监控脚本 (Traffic Monitor)
#  - 监控网卡日流量 / 月流量
#  - 阈值告警 + Telegram 通报
#  - 终端交互：方向键 / j-k 上下选择，回车确认
#  - Telegram：内联按钮菜单 + 对话式配置（非常驻底部键盘）
#===============================================================================
set -euo pipefail

#-------------------------------------------------------------------------------
# 路径与常量
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
CONFIG_FILE="${SCRIPT_DIR}/config.conf"
STATE_DIR="${SCRIPT_DIR}/state"
STATE_FILE="${STATE_DIR}/traffic.state"
LOG_FILE="${SCRIPT_DIR}/traffic-monitor.log"
ALERT_STATE_FILE="${STATE_DIR}/alerts.state"
PID_FILE="${STATE_DIR}/monitor.pid"
TG_OFFSET_FILE="${STATE_DIR}/tg_offset"
TG_SESSION_FILE="${STATE_DIR}/tg_session"
CRON_TAG="traffic-monitor"

# 默认配置（可被 config.conf 覆盖）
INTERFACE="eth0"
DAILY_LIMIT_GB="100"
MONTHLY_LIMIT_GB="0"          # 0 = 不限制
CHECK_INTERVAL_SEC="300"      # 守护模式检查间隔（秒）
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_ENABLED="false"
ALERT_THRESHOLDS="50,80,90,95,100"  # 百分比
ALERT_COOLDOWN_MIN="60"       # 同一阈值重复通知冷却（分钟）
COUNT_MODE="total"            # total | rx | tx  （总计/仅下载/仅上传）
EXCLUDE_LO="true"             # 排除 loopback
LOG_MAX_LINES="2000"
TIMEZONE=""                   # 空则用系统时区
HOSTNAME_TAG="$(hostname -s 2>/dev/null || echo server)"

#-------------------------------------------------------------------------------
# 工具函数
#-------------------------------------------------------------------------------
c_red()    { printf '\033[0;31m%s\033[0m' "$*"; }
c_green()  { printf '\033[0;32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m' "$*"; }
c_blue()   { printf '\033[0;34m%s\033[0m' "$*"; }
c_cyan()   { printf '\033[0;36m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }
c_rev()    { printf '\033[7m%s\033[0m' "$*"; }

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
  # 日志轮转
  if [[ -f "$LOG_FILE" ]]; then
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if (( lines > LOG_MAX_LINES )); then
      tail -n "$((LOG_MAX_LINES / 2))" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

ensure_dirs() {
  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE" 2>/dev/null || true
}

# 浮点/数值计算（awk，不依赖 bc）
calc() {
  awk "BEGIN { printf \"%.6f\", ($*) }"
}

# 字节格式化
fmt_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN {
    if (b < 0) b = 0
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]
    else printf "%.2f %s", b, u[i]
  }'
}

# GB -> 字节
gb_to_bytes() {
  awk -v g="$1" 'BEGIN { printf "%.0f", g * 1024 * 1024 * 1024 }'
}

# 字节 -> GB（保留 2 位）
bytes_to_gb() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }'
}

# 百分比
pct() {
  local used="$1" limit="$2"
  awk -v u="$used" -v l="$limit" 'BEGIN {
    if (l <= 0) { print "0.00"; exit }
    p = u * 100 / l
    if (p > 999) p = 999
    printf "%.2f", p
  }'
}

progress_bar() {
  local percent="$1"
  local width="${2:-30}"
  local filled empty i p
  p=$(awk -v p="$percent" 'BEGIN { if (p<0)p=0; if (p>100)p=100; printf "%d", p }')
  filled=$(( p * width / 100 ))
  empty=$(( width - filled ))
  printf "["
  for ((i=0; i<filled; i++)); do printf "█"; done
  for ((i=0; i<empty; i++)); do printf "░"; done
  printf "] %s%%" "$percent"
}

#-------------------------------------------------------------------------------
# 配置加载 / 保存
#-------------------------------------------------------------------------------
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  if [[ -n "$TIMEZONE" ]]; then
    export TZ="$TIMEZONE"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# 流量监控配置 - 由 traffic-monitor.sh 自动生成
# 修改后下次运行生效；也可用菜单修改

INTERFACE="${INTERFACE}"
DAILY_LIMIT_GB="${DAILY_LIMIT_GB}"
MONTHLY_LIMIT_GB="${MONTHLY_LIMIT_GB}"
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC}"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
TG_ENABLED="${TG_ENABLED}"
ALERT_THRESHOLDS="${ALERT_THRESHOLDS}"
ALERT_COOLDOWN_MIN="${ALERT_COOLDOWN_MIN}"
COUNT_MODE="${COUNT_MODE}"
EXCLUDE_LO="${EXCLUDE_LO}"
LOG_MAX_LINES="${LOG_MAX_LINES}"
TIMEZONE="${TIMEZONE}"
HOSTNAME_TAG="${HOSTNAME_TAG}"
EOF
  chmod 600 "$CONFIG_FILE"
  log INFO "配置已保存到 $CONFIG_FILE"
}

#-------------------------------------------------------------------------------
# 网卡流量读取（/proc/net/dev）
#-------------------------------------------------------------------------------
list_interfaces() {
  awk -F: 'NR>2 { gsub(/ /,"",$1); if ($1!="") print $1 }' /proc/net/dev
}

# 返回: rx_bytes tx_bytes
read_iface_bytes() {
  local iface="$1"
  local line rx tx
  line=$(awk -v i="$iface" -F: 'NR>2 {
    gsub(/ /,"",$1)
    if ($1==i) { print $2; exit }
  }' /proc/net/dev)
  if [[ -z "$line" ]]; then
    echo "0 0"
    return 1
  fi
  # fields: rx_bytes rx_packets ... tx_bytes ...
  rx=$(echo "$line" | awk '{print $1}')
  tx=$(echo "$line" | awk '{print $9}')
  echo "${rx:-0} ${tx:-0}"
}

# 汇总：指定接口；若 INTERFACE=all 则汇总所有非 lo
get_current_bytes() {
  local total_rx=0 total_tx=0 rx tx
  if [[ "$INTERFACE" == "all" ]]; then
    while read -r iface; do
      [[ "$EXCLUDE_LO" == "true" && "$iface" == "lo" ]] && continue
      read -r rx tx < <(read_iface_bytes "$iface")
      total_rx=$((total_rx + rx))
      total_tx=$((total_tx + tx))
    done < <(list_interfaces)
  else
    read -r total_rx total_tx < <(read_iface_bytes "$INTERFACE") || true
  fi
  echo "$total_rx $total_tx"
}

# 按 COUNT_MODE 取用量字节
mode_bytes() {
  local rx="$1" tx="$2"
  case "$COUNT_MODE" in
    rx) echo "$rx" ;;
    tx) echo "$tx" ;;
    *)  echo $((rx + tx)) ;;
  esac
}

#-------------------------------------------------------------------------------
# 状态文件：跨重启累计日/月用量
# 原理：保存上次读取的网卡计数器 + 当日/当月累计
# 网卡计数器回绕或重启时，按增量只加正差值
#-------------------------------------------------------------------------------
# state 格式 (key=value):
# day=YYYY-MM-DD
# month=YYYY-MM
# day_rx=... day_tx=...
# month_rx=... month_tx=...
# last_rx=... last_tx=...
# last_update=unix

init_state_if_needed() {
  ensure_dirs
  local today month now rx tx
  today="$(date +%Y-%m-%d)"
  month="$(date +%Y-%m)"
  now="$(date +%s)"
  read -r rx tx < <(get_current_bytes)

  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" <<EOF
day=${today}
month=${month}
day_rx=0
day_tx=0
month_rx=0
month_tx=0
last_rx=${rx}
last_tx=${tx}
last_update=${now}
EOF
    log INFO "初始化流量状态 day=$today iface=$INTERFACE rx=$rx tx=$tx"
    return
  fi
}

# 加载 state 到变量
load_state() {
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  day="${day:-}"
  month="${month:-}"
  day_rx="${day_rx:-0}"
  day_tx="${day_tx:-0}"
  month_rx="${month_rx:-0}"
  month_tx="${month_tx:-0}"
  last_rx="${last_rx:-0}"
  last_tx="${last_tx:-0}"
  last_update="${last_update:-0}"
}

save_state() {
  cat > "$STATE_FILE" <<EOF
day=${day}
month=${month}
day_rx=${day_rx}
day_tx=${day_tx}
month_rx=${month_rx}
month_tx=${month_tx}
last_rx=${last_rx}
last_tx=${last_tx}
last_update=${last_update}
EOF
}

# 更新累计流量（核心）
update_traffic() {
  init_state_if_needed
  load_state

  local today month now cur_rx cur_tx d_rx d_tx
  today="$(date +%Y-%m-%d)"
  month="$(date +%Y-%m)"
  now="$(date +%s)"
  read -r cur_rx cur_tx < <(get_current_bytes)

  # 日切
  if [[ "$day" != "$today" ]]; then
    log INFO "日切: $day -> $today (昨日用量 RX=$(fmt_bytes "$day_rx") TX=$(fmt_bytes "$day_tx"))"
    day="$today"
    day_rx=0
    day_tx=0
    # 清理当日告警记录
    : > "$ALERT_STATE_FILE" 2>/dev/null || true
  fi

  # 月切
  local cur_month
  cur_month="$(date +%Y-%m)"
  if [[ "$month" != "$cur_month" ]]; then
    log INFO "月切: $month -> $cur_month"
    month="$cur_month"
    month_rx=0
    month_tx=0
  fi

  # 增量（处理重启/回绕：若当前 < last，视为重启，从 0 开始记本次增量）
  if (( cur_rx >= last_rx )); then
    d_rx=$((cur_rx - last_rx))
  else
    d_rx=$cur_rx
    log WARN "RX 计数器回绕/重启: last=$last_rx cur=$cur_rx"
  fi
  if (( cur_tx >= last_tx )); then
    d_tx=$((cur_tx - last_tx))
  else
    d_tx=$cur_tx
    log WARN "TX 计数器回绕/重启: last=$last_tx cur=$cur_tx"
  fi

  day_rx=$((day_rx + d_rx))
  day_tx=$((day_tx + d_tx))
  month_rx=$((month_rx + d_rx))
  month_tx=$((month_tx + d_tx))
  last_rx=$cur_rx
  last_tx=$cur_tx
  last_update=$now

  save_state
}

#-------------------------------------------------------------------------------
# Telegram API · 内联菜单 + 对话式配置
#-------------------------------------------------------------------------------
# 交互说明：
#   - 使用 Inline Keyboard（消息下方按钮），非常驻底部键盘
#   - /start /menu 打开主菜单；配置项点选后可输入文本完成修改
#   - 会话状态保存在 tg_session（awaiting=字段名）
# callback data 约定（≤64 字节）：
#   main | status | report | check | help | cfg | cfgview | sched | log
#   set:daily|monthly|thr|cool|int|host | iface | mode | mode:xx | if:xx
#   daemon:start|stop | cron:N | cron:report | cron:rm
#   reset:ask | reset:yes | cancel | back:cfg | back:main
#-------------------------------------------------------------------------------

tg_ok() {
  echo "$1" | grep -q '"ok":true'
}

# 会话：awaiting=字段  since=unix
tg_session_clear() {
  rm -f "$TG_SESSION_FILE" 2>/dev/null || true
}

tg_session_set() {
  local awaiting="$1"
  ensure_dirs
  cat > "$TG_SESSION_FILE" <<EOF
awaiting=${awaiting}
since=$(date +%s)
EOF
}

tg_session_get_awaiting() {
  local awaiting="" since=0 now
  if [[ -f "$TG_SESSION_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$TG_SESSION_FILE"
    now=$(date +%s)
    # 10 分钟超时
    if [[ -n "${since:-}" ]] && (( now - since > 600 )); then
      tg_session_clear
      echo ""
      return
    fi
    echo "${awaiting:-}"
  else
    echo ""
  fi
}

# 用 python 生成 inline_keyboard JSON（stdin 每行: 文案|callback_data ，空行分行）
tg_kb_from_rows() {
  python3 -c '
import json, sys
rows, row = [], []
for line in sys.stdin:
    line = line.rstrip("\n")
    if line == "":
        if row:
            rows.append(row)
            row = []
        continue
    if "|" not in line:
        continue
    text, data = line.split("|", 1)
    row.append({"text": text, "callback_data": data[:64]})
if row:
    rows.append(row)
print(json.dumps({"inline_keyboard": rows}, ensure_ascii=False))
'
}

tg_kb_main() {
  tg_kb_from_rows <<'EOF'
📊 状态|status
📡 报告|report

🔍 检查|check
⚙️ 配置|cfg

🕐 调度|sched
📋 当前配置|cfgview

📜 日志|log
ℹ️ 帮助|help
EOF
}

tg_kb_nav_main() {
  tg_kb_from_rows <<'EOF'
🏠 主菜单|main
EOF
}

tg_kb_cfg() {
  tg_kb_from_rows <<EOF
🖥 网卡 (${INTERFACE})|iface
📅 日限额 (${DAILY_LIMIT_GB}G)|set:daily

📆 月限额 (${MONTHLY_LIMIT_GB}G)|set:monthly
📐 统计模式 (${COUNT_MODE})|mode

🚨 告警阈值|set:thr
⏱ 冷却 (${ALERT_COOLDOWN_MIN}m)|set:cool

🔁 检查间隔 (${CHECK_INTERVAL_SEC}s)|set:int
🏷 主机标识|set:host

🗑 清零今日|reset:ask
🏠 主菜单|main
EOF
}

tg_kb_mode() {
  local t_total="total" t_rx="rx" t_tx="tx"
  [[ "$COUNT_MODE" == "total" ]] && t_total="✓ total"
  [[ "$COUNT_MODE" == "rx" ]] && t_rx="✓ rx"
  [[ "$COUNT_MODE" == "tx" ]] && t_tx="✓ tx"
  tg_kb_from_rows <<EOF
${t_total}|mode:total
${t_rx}|mode:rx
${t_tx}|mode:tx

« 返回配置|cfg
EOF
}

tg_kb_iface() {
  {
    while read -r iface; do
      [[ -z "$iface" ]] && continue
      if [[ "$iface" == "$INTERFACE" ]]; then
        echo "✓ ${iface}|if:${iface}"
      else
        echo "${iface}|if:${iface}"
      fi
    done < <(list_interfaces)
    if [[ "$INTERFACE" == "all" ]]; then
      echo "✓ all (全部)|if:all"
    else
      echo "all (全部)|if:all"
    fi
    echo ""
    echo "« 返回配置|cfg"
  } | tg_kb_from_rows
}

tg_kb_sched() {
  local dstat="未运行"
  is_daemon_running && dstat="运行中"
  local cstat="未安装"
  has_cron && cstat="已安装"
  tg_kb_from_rows <<EOF
🟢 启动守护|daemon:start
🔴 停止守护|daemon:stop

⏱ Cron 每1分|cron:1
⏱ Cron 每5分|cron:5

⏱ Cron 每15分|cron:15
📰 日报 9/21点|cron:report

🗑 移除 Cron|cron:rm
🏠 主菜单|main
EOF
}

tg_kb_reset_confirm() {
  tg_kb_from_rows <<'EOF'
⚠️ 确认清零|reset:yes
取消|cfg
EOF
}

tg_kb_cancel_input() {
  tg_kb_from_rows <<'EOF'
✖ 取消输入|cancel
EOF
}

# 去掉旧版常驻 Reply Keyboard
tg_remove_reply_keyboard() {
  local chat_id="${1:-$TG_CHAT_ID}"
  [[ -z "$TG_BOT_TOKEN" || -z "$chat_id" ]] && return 0
  curl -sS -m 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=⌨️ 已切换为消息内菜单（旧底部键盘已移除）" \
    --data-urlencode "reply_markup={\"remove_keyboard\":true}" \
    >/dev/null 2>&1 || true
}

# 通用发送：text, [chat_id], [reply_markup_json]
tg_api_send() {
  local text="$1"
  local chat_id="${2:-$TG_CHAT_ID}"
  local markup="${3:-}"
  local parse_mode="${4:-HTML}"

  [[ -z "$TG_BOT_TOKEN" || -z "$chat_id" ]] && return 1

  local args=(
    -sS -m 15 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    --data-urlencode "chat_id=${chat_id}"
    --data-urlencode "text=${text}"
    --data-urlencode "parse_mode=${parse_mode}"
    --data-urlencode "disable_web_page_preview=true"
  )
  if [[ -n "$markup" ]]; then
    args+=(--data-urlencode "reply_markup=${markup}")
  fi
  local resp
  resp=$(curl "${args[@]}" 2>&1) || {
    log ERROR "TG send 失败: $resp"
    return 1
  }
  if tg_ok "$resp"; then
    log INFO "Telegram 消息已发送"
    return 0
  fi
  log ERROR "Telegram API 异常: $resp"
  return 1
}

# 编辑消息（内联菜单翻页/刷新）
tg_api_edit() {
  local chat_id="$1" msg_id="$2" text="$3" markup="${4:-}"
  local args=(
    -sS -m 15 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText"
    --data-urlencode "chat_id=${chat_id}"
    --data-urlencode "message_id=${msg_id}"
    --data-urlencode "text=${text}"
    --data-urlencode "parse_mode=HTML"
    --data-urlencode "disable_web_page_preview=true"
  )
  if [[ -n "$markup" ]]; then
    args+=(--data-urlencode "reply_markup=${markup}")
  fi
  local resp
  resp=$(curl "${args[@]}" 2>&1) || true
  # 内容未变时 API 报错，忽略
  tg_ok "$resp" && return 0
  echo "$resp" | grep -q 'message is not modified' && return 0
  log DEBUG "editMessage 响应: $resp"
  return 0
}

tg_answer_cb() {
  local cb_id="$1"
  local text="${2:-}"
  local args=(
    -sS -m 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/answerCallbackQuery"
    --data-urlencode "callback_query_id=${cb_id}"
  )
  [[ -n "$text" ]] && args+=(--data-urlencode "text=${text}" --data-urlencode "show_alert=false")
  curl "${args[@]}" >/dev/null 2>&1 || true
}

# 告警/报告用的发送（尊重 TG_ENABLED）
tg_send() {
  local text="$1"
  local parse_mode="${2:-HTML}"
  local with_menu="${3:-false}"

  if [[ "$TG_ENABLED" != "true" ]]; then
    log DEBUG "TG 未启用，跳过发送"
    return 0
  fi
  if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    log WARN "TG_BOT_TOKEN 或 TG_CHAT_ID 未配置"
    return 1
  fi
  local markup=""
  if [[ "$with_menu" == "true" ]]; then
    markup="$(tg_kb_nav_main)"
  fi
  tg_api_send "$text" "$TG_CHAT_ID" "$markup" "$parse_mode"
}

tg_set_commands() {
  [[ -z "$TG_BOT_TOKEN" ]] && return 1
  local cmds='[{"command":"start","description":"打开主菜单"},{"command":"menu","description":"打开主菜单"},{"command":"status","description":"流量状态"},{"command":"config","description":"配置中心"},{"command":"help","description":"帮助"}]'
  curl -sS -m 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/setMyCommands" \
    --data-urlencode "commands=${cmds}" >/dev/null 2>&1 || true
}

tg_ui_main_text() {
  cat <<EOF
📡 <b>流量监控</b> · <code>${HOSTNAME_TAG}</code>

点选下方按钮操作。配置修改后立即生效。
发送 /menu 可随时回到此菜单。
EOF
}

tg_ui_help_text() {
  cat <<EOF
ℹ️ <b>使用说明</b>

• 菜单为<strong>消息内按钮</strong>，不会常驻屏幕底部
• 所有配置均可在「⚙️ 配置」中点选 / 输入完成
• 输入过程中发 /cancel 可取消
• 仅授权 Chat ID 可操作

命令: /menu /status /config /help
主机: <code>${HOSTNAME_TAG}</code>
EOF
}

build_status_html() {
  update_traffic
  load_state
  local day_used month_used day_limit_b day_p remain remain_gb
  day_used=$(mode_bytes "$day_rx" "$day_tx")
  month_used=$(mode_bytes "$month_rx" "$month_tx")
  day_limit_b=$(gb_to_bytes "$DAILY_LIMIT_GB")
  day_p=$(pct "$day_used" "$day_limit_b")
  remain=$((day_limit_b - day_used))
  (( remain < 0 )) && remain=0
  remain_gb=$(bytes_to_gb "$remain")

  local month_line daemon_line cron_line
  if awk -v m="$MONTHLY_LIMIT_GB" 'BEGIN { exit !(m+0 > 0) }'; then
    local ml mp
    ml=$(gb_to_bytes "$MONTHLY_LIMIT_GB")
    mp=$(pct "$month_used" "$ml")
    month_line="月用量: $(fmt_bytes "$month_used") / $(fmt_bytes "$ml") (${mp}%)"
  else
    month_line="月用量: $(fmt_bytes "$month_used")（未设月限额）"
  fi
  if is_daemon_running; then
    daemon_line="守护: ✅ 运行中 (PID $(cat "$PID_FILE" 2>/dev/null))"
  else
    daemon_line="守护: ⚪ 未运行"
  fi
  if has_cron; then
    cron_line="Cron: ✅ 已安装"
  else
    cron_line="Cron: ⚪ 未安装"
  fi

  cat <<EOF
📡 <b>流量状态</b>
主机: <code>${HOSTNAME_TAG}</code>
接口: <code>${INTERFACE}</code> | 模式: <code>${COUNT_MODE}</code>

日用量: <b>$(fmt_bytes "$day_used")</b> / $(fmt_bytes "$day_limit_b") (<b>${day_p}%</b>)
剩余: <b>${remain_gb} GB</b>
  RX: $(fmt_bytes "$day_rx")
  TX: $(fmt_bytes "$day_tx")
${month_line}

${daemon_line}
${cron_line}
更新: $(date '+%Y-%m-%d %H:%M:%S')
EOF
}

build_config_html() {
  cat <<EOF
⚙️ <b>当前配置</b>
主机标识: <code>${HOSTNAME_TAG}</code>
监控网卡: <code>${INTERFACE}</code>
日限额: <b>${DAILY_LIMIT_GB}</b> GB
月限额: <b>${MONTHLY_LIMIT_GB}</b> GB <i>(0=不限)</i>
统计模式: <code>${COUNT_MODE}</code>
告警阈值: <code>${ALERT_THRESHOLDS}</code> %
告警冷却: ${ALERT_COOLDOWN_MIN} 分钟
检查间隔: ${CHECK_INTERVAL_SEC} 秒
TG 启用: <code>${TG_ENABLED}</code>
Chat ID: <code>${TG_CHAT_ID}</code>
EOF
}

# 展示/刷新 UI：优先 edit，否则 send
tg_show() {
  local chat_id="$1" text="$2" markup="$3"
  local msg_id="${4:-}"
  if [[ -n "$msg_id" && "$msg_id" != "0" ]]; then
    tg_api_edit "$chat_id" "$msg_id" "$text" "$markup"
  else
    tg_api_send "$text" "$chat_id" "$markup"
  fi
}

tg_prompt_input() {
  local chat_id="$1" field="$2" hint="$3" msg_id="${4:-}"
  tg_session_set "$field"
  local text="✏️ <b>请输入新值</b>

${hint}

直接发送文本即可。
发送 /cancel 或点取消 可放弃。"
  tg_show "$chat_id" "$text" "$(tg_kb_cancel_input)" "$msg_id"
}

# 应用文本配置
tg_apply_input() {
  local chat_id="$1" field="$2" value="$3"
  value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  case "$field" in
    daily)
      if ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        tg_api_send "❌ 请输入有效数字（GB）" "$chat_id" "$(tg_kb_cancel_input)"
        return 1
      fi
      DAILY_LIMIT_GB="$value"
      ;;
    monthly)
      if ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        tg_api_send "❌ 请输入有效数字（GB，0=不限）" "$chat_id" "$(tg_kb_cancel_input)"
        return 1
      fi
      MONTHLY_LIMIT_GB="$value"
      ;;
    thr)
      value="$(echo "$value" | tr -d ' ')"
      if ! [[ "$value" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        tg_api_send "❌ 格式: 50,80,90,95,100" "$chat_id" "$(tg_kb_cancel_input)"
        return 1
      fi
      ALERT_THRESHOLDS="$value"
      ;;
    cool)
      if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
        tg_api_send "❌ 请输入正整数（分钟）" "$chat_id" "$(tg_kb_cancel_input)"
        return 1
      fi
      ALERT_COOLDOWN_MIN="$value"
      ;;
    int)
      if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 10 )); then
        tg_api_send "❌ 请输入 ≥10 的秒数" "$chat_id" "$(tg_kb_cancel_input)"
        return 1
      fi
      CHECK_INTERVAL_SEC="$value"
      ;;
    host)
      if [[ -z "$value" || ${#value} -gt 64 ]]; then
        tg_api_send "❌ 主机标识不能为空且 ≤64 字符" "$chat_id" "$(tg_kb_cancel_input)"
        return 1
      fi
      HOSTNAME_TAG="$value"
      ;;
    *)
      tg_api_send "❌ 未知配置项" "$chat_id" "$(tg_kb_main)"
      tg_session_clear
      return 1
      ;;
  esac

  save_config
  load_config
  tg_session_clear
  log INFO "TG 配置已更新 field=$field value=$value"
  tg_api_send "✅ 已更新并保存

$(build_config_html)" "$chat_id" "$(tg_kb_cfg)"
  return 0
}

tg_do_reset_day() {
  update_traffic
  load_state
  day_rx=0
  day_tx=0
  save_state
  : > "$ALERT_STATE_FILE" 2>/dev/null || true
  log WARN "TG 用户清零今日流量"
}

tg_do_daemon_start() {
  if is_daemon_running || [[ "${IN_DAEMON:-0}" == "1" ]]; then
    echo "already"
    return 0
  fi
  nohup bash "$SCRIPT_PATH" --daemon >> "$LOG_FILE" 2>&1 &
  sleep 0.6
  if is_daemon_running; then
    echo "ok"
  else
    echo "fail"
  fi
}

tg_do_daemon_stop() {
  if [[ "${IN_DAEMON:-0}" == "1" ]]; then
    echo "self"
    return 0
  fi
  if ! is_daemon_running; then
    echo "none"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null || true
  sleep 0.5
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "ok"
}

# 处理 callback
tg_handle_callback() {
  local chat_id="$1" msg_id="$2" cb_id="$3" data="$4"

  if [[ -n "$TG_CHAT_ID" && "$chat_id" != "$TG_CHAT_ID" ]]; then
    tg_answer_cb "$cb_id" "未授权"
    log WARN "忽略未授权 callback chat=$chat_id"
    return 0
  fi

  log INFO "TG callback data=$data chat=$chat_id"
  local text markup

  case "$data" in
    main)
      tg_session_clear
      tg_answer_cb "$cb_id"
      tg_show "$chat_id" "$(tg_ui_main_text)" "$(tg_kb_main)" "$msg_id"
      ;;
    status)
      tg_answer_cb "$cb_id" "刷新中…"
      tg_show "$chat_id" "$(build_status_html)" "$(tg_kb_nav_main)" "$msg_id"
      ;;
    report)
      tg_answer_cb "$cb_id" "生成报告…"
      TG_ENABLED="true"
      local old="$TG_CHAT_ID"
      TG_CHAT_ID="$chat_id"
      send_status_report || tg_api_send "❌ 报告失败" "$chat_id" "$(tg_kb_nav_main)"
      TG_CHAT_ID="$old"
      ;;
    check)
      tg_answer_cb "$cb_id" "检查中…"
      check_and_alert || true
      tg_show "$chat_id" "🔍 <b>检查完成</b>

$(build_status_html)" "$(tg_kb_nav_main)" "$msg_id"
      ;;
    help)
      tg_answer_cb "$cb_id"
      tg_show "$chat_id" "$(tg_ui_help_text)" "$(tg_kb_nav_main)" "$msg_id"
      ;;
    cfg|back:cfg)
      tg_session_clear
      tg_answer_cb "$cb_id"
      tg_show "$chat_id" "⚙️ <b>配置中心</b>

点选要修改的项；需要输入时按提示发送文本。

$(build_config_html)" "$(tg_kb_cfg)" "$msg_id"
      ;;
    cfgview)
      tg_answer_cb "$cb_id"
      tg_show "$chat_id" "$(build_config_html)" "$(tg_kb_cfg)" "$msg_id"
      ;;
    sched)
      tg_answer_cb "$cb_id"
      local dline cline
      if is_daemon_running; then
        dline="守护: ✅ 运行中 (PID $(cat "$PID_FILE" 2>/dev/null))"
      else
        dline="守护: ⚪ 未运行"
      fi
      if has_cron; then
        cline="Cron: ✅ 已安装"
      else
        cline="Cron: ⚪ 未安装"
      fi
      tg_show "$chat_id" "🕐 <b>调度管理</b>

${dline}
${cline}
检查间隔: ${CHECK_INTERVAL_SEC}s" "$(tg_kb_sched)" "$msg_id"
      ;;
    log)
      tg_answer_cb "$cb_id"
      local logs
      logs=$(tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' || echo "(无日志)")
      tg_show "$chat_id" "📜 <b>最近日志</b>
<pre>${logs}</pre>" "$(tg_kb_nav_main)" "$msg_id"
      ;;
    iface)
      tg_answer_cb "$cb_id"
      tg_show "$chat_id" "🖥 <b>选择监控网卡</b>
当前: <code>${INTERFACE}</code>" "$(tg_kb_iface)" "$msg_id"
      ;;
    if:*)
      local new_if="${data#if:}"
      # 校验网卡名
      if [[ "$new_if" != "all" ]] && ! list_interfaces | grep -qx "$new_if"; then
        tg_answer_cb "$cb_id" "无效网卡"
        return 0
      fi
      INTERFACE="$new_if"
      save_config
      load_config
      tg_answer_cb "$cb_id" "已设为 $new_if"
      tg_show "$chat_id" "✅ 网卡已设为 <code>${INTERFACE}</code>

$(build_config_html)" "$(tg_kb_cfg)" "$msg_id"
      ;;
    mode)
      tg_answer_cb "$cb_id"
      tg_show "$chat_id" "📐 <b>统计模式</b>
当前: <code>${COUNT_MODE}</code>

total=上下行合计 · rx=仅下载 · tx=仅上传" "$(tg_kb_mode)" "$msg_id"
      ;;
    mode:total|mode:rx|mode:tx)
      COUNT_MODE="${data#mode:}"
      save_config
      load_config
      tg_answer_cb "$cb_id" "模式: $COUNT_MODE"
      tg_show "$chat_id" "✅ 统计模式: <code>${COUNT_MODE}</code>

$(build_config_html)" "$(tg_kb_cfg)" "$msg_id"
      ;;
    set:daily)
      tg_answer_cb "$cb_id"
      tg_prompt_input "$chat_id" "daily" "当前日限额: <b>${DAILY_LIMIT_GB}</b> GB
请发送新的日限额数字，例如 <code>100</code>" "$msg_id"
      ;;
    set:monthly)
      tg_answer_cb "$cb_id"
      tg_prompt_input "$chat_id" "monthly" "当前月限额: <b>${MONTHLY_LIMIT_GB}</b> GB（0=不限）
请发送新数字，例如 <code>3000</code> 或 <code>0</code>" "$msg_id"
      ;;
    set:thr)
      tg_answer_cb "$cb_id"
      tg_prompt_input "$chat_id" "thr" "当前阈值: <code>${ALERT_THRESHOLDS}</code>
请发送逗号分隔百分比，例如 <code>50,80,90,95,100</code>" "$msg_id"
      ;;
    set:cool)
      tg_answer_cb "$cb_id"
      tg_prompt_input "$chat_id" "cool" "当前冷却: <b>${ALERT_COOLDOWN_MIN}</b> 分钟
请发送正整数，例如 <code>60</code>" "$msg_id"
      ;;
    set:int)
      tg_answer_cb "$cb_id"
      tg_prompt_input "$chat_id" "int" "当前检查间隔: <b>${CHECK_INTERVAL_SEC}</b> 秒
请发送 ≥10 的秒数，例如 <code>300</code>
<i>守护进程需重启后间隔才完全按新值循环（下次 long-poll 后生效）</i>" "$msg_id"
      ;;
    set:host)
      tg_answer_cb "$cb_id"
      tg_prompt_input "$chat_id" "host" "当前主机标识: <code>${HOSTNAME_TAG}</code>
请发送新标识（用于报告标题）" "$msg_id"
      ;;
    cancel)
      tg_session_clear
      tg_answer_cb "$cb_id" "已取消"
      tg_show "$chat_id" "已取消输入。

$(build_config_html)" "$(tg_kb_cfg)" "$msg_id"
      ;;
    reset:ask)
      tg_answer_cb "$cb_id"
      tg_show "$chat_id" "🗑 <b>清零今日累计流量？</b>

此操作不可撤销（告警冷却记录也会清空）。" "$(tg_kb_reset_confirm)" "$msg_id"
      ;;
    reset:yes)
      tg_do_reset_day
      tg_answer_cb "$cb_id" "已清零"
      tg_show "$chat_id" "✅ 今日累计已清零

$(build_status_html)" "$(tg_kb_nav_main)" "$msg_id"
      ;;
    daemon:start)
      local r dmsg
      r=$(tg_do_daemon_start)
      case "$r" in
        already) tg_answer_cb "$cb_id" "已在运行"; dmsg="✅ 守护已在运行" ;;
        ok) tg_answer_cb "$cb_id" "已启动"; dmsg="✅ 守护已启动" ;;
        *) tg_answer_cb "$cb_id" "启动失败"; dmsg="❌ 启动失败" ;;
      esac
      tg_show "$chat_id" "🕐 <b>调度</b>

${dmsg}
PID: $(cat "$PID_FILE" 2>/dev/null || echo -)" "$(tg_kb_sched)" "$msg_id"
      ;;
    daemon:stop)
      local r
      r=$(tg_do_daemon_stop)
      case "$r" in
        self)
          tg_answer_cb "$cb_id" "即将停止"
          tg_api_send "🛑 守护进程即将退出…
之后需在服务器执行 --start 或重新部署后再用菜单。" "$chat_id"
          ( sleep 1; kill $$ 2>/dev/null ) &
          ;;
        none)
          tg_answer_cb "$cb_id" "未运行"
          tg_show "$chat_id" "ℹ️ 守护未运行" "$(tg_kb_sched)" "$msg_id"
          ;;
        ok)
          tg_answer_cb "$cb_id" "已停止"
          tg_show "$chat_id" "✅ 守护已停止" "$(tg_kb_sched)" "$msg_id"
          ;;
      esac
      ;;
    cron:report)
      install_cron_report >/dev/null
      tg_answer_cb "$cb_id" "已装日报"
      tg_show "$chat_id" "✅ 已安装每日 09:00 / 21:00 TG 报告" "$(tg_kb_sched)" "$msg_id"
      ;;
    cron:rm)
      remove_cron >/dev/null
      tg_answer_cb "$cb_id" "已移除"
      tg_show "$chat_id" "✅ 已移除相关 crontab" "$(tg_kb_sched)" "$msg_id"
      ;;
    cron:*)
      local mins="${data#cron:}"
      if [[ "$mins" =~ ^[0-9]+$ ]]; then
        install_cron "$mins" >/dev/null
        tg_answer_cb "$cb_id" "Cron ${mins}m"
        tg_show "$chat_id" "✅ 已安装 crontab：每 ${mins} 分钟检查" "$(tg_kb_sched)" "$msg_id"
      else
        tg_answer_cb "$cb_id" "无效"
      fi
      ;;
    *)
      tg_answer_cb "$cb_id" "未知操作"
      tg_show "$chat_id" "$(tg_ui_main_text)" "$(tg_kb_main)" "$msg_id"
      ;;
  esac
}

# 处理文本消息
tg_handle_message() {
  local chat_id="$1"
  local text="$2"
  local r

  if [[ -n "$TG_CHAT_ID" && "$chat_id" != "$TG_CHAT_ID" ]]; then
    log WARN "忽略未授权 chat_id=$chat_id"
    return 0
  fi

  # 去掉 /cmd@BotName 后缀
  if [[ "$text" == /* ]]; then
    local first rest
    first="${text%% *}"
    if [[ "$text" == *" "* ]]; then rest="${text#* }"; else rest=""; fi
    first="${first%%@*}"
    if [[ -n "$rest" ]]; then text="$first $rest"; else text="$first"; fi
  fi
  text="$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  # 取消
  if [[ "$text" == "/cancel" ]]; then
    tg_session_clear
    tg_api_send "已取消。" "$chat_id" "$(tg_kb_main)"
    return 0
  fi

  # 若在等待配置输入
  local awaiting
  awaiting="$(tg_session_get_awaiting)"
  if [[ -n "$awaiting" ]]; then
    if [[ "$text" == /* ]]; then
      tg_session_clear
    else
      tg_apply_input "$chat_id" "$awaiting" "$text"
      return 0
    fi
  fi

  case "$text" in
    /start)
      tg_remove_reply_keyboard "$chat_id"
      tg_session_clear
      tg_set_commands
      tg_api_send "$(tg_ui_main_text)" "$chat_id" "$(tg_kb_main)"
      ;;
    /menu)
      tg_session_clear
      tg_api_send "$(tg_ui_main_text)" "$chat_id" "$(tg_kb_main)"
      ;;
    /config)
      tg_session_clear
      tg_api_send "⚙️ <b>配置中心</b>

$(build_config_html)" "$chat_id" "$(tg_kb_cfg)"
      ;;
    /status)
      tg_api_send "$(build_status_html)" "$chat_id" "$(tg_kb_nav_main)"
      ;;
    /report)
      TG_ENABLED="true"
      TG_CHAT_ID="$chat_id"
      send_status_report || tg_api_send "❌ 报告失败" "$chat_id" "$(tg_kb_nav_main)"
      ;;
    /check)
      check_and_alert || true
      tg_api_send "🔍 <b>检查完成</b>

$(build_status_html)" "$chat_id" "$(tg_kb_nav_main)"
      ;;
    /help)
      tg_api_send "$(tg_ui_help_text)" "$chat_id" "$(tg_kb_nav_main)"
      ;;
    # 兼容旧版底部键盘文案 → 打开新内联菜单或对应功能
    "📊 状态"|"状态")
      tg_api_send "$(build_status_html)" "$chat_id" "$(tg_kb_nav_main)"
      ;;
    "📡 报告"|"报告")
      TG_ENABLED="true"; TG_CHAT_ID="$chat_id"
      send_status_report || tg_api_send "❌ 报告失败" "$chat_id" "$(tg_kb_nav_main)"
      ;;
    "🔍 检查"|"检查")
      check_and_alert || true
      tg_api_send "🔍 <b>检查完成</b>

$(build_status_html)" "$chat_id" "$(tg_kb_nav_main)"
      ;;
    "📋 菜单"|"菜单"|"ℹ️ 帮助"|"帮助")
      tg_remove_reply_keyboard "$chat_id"
      tg_api_send "$(tg_ui_main_text)" "$chat_id" "$(tg_kb_main)"
      ;;
    "🟢 启动守护"|"启动守护")
      r=$(tg_do_daemon_start)
      case "$r" in
        already|ok) tg_api_send "✅ 守护运行中 PID $(cat "$PID_FILE" 2>/dev/null)" "$chat_id" "$(tg_kb_sched)" ;;
        *) tg_api_send "❌ 启动失败" "$chat_id" "$(tg_kb_sched)" ;;
      esac
      ;;
    "🔴 停止守护"|"停止守护")
      r=$(tg_do_daemon_stop)
      case "$r" in
        self)
          tg_api_send "🛑 守护即将退出…" "$chat_id"
          ( sleep 1; kill $$ 2>/dev/null ) &
          ;;
        ok) tg_api_send "✅ 已停止" "$chat_id" "$(tg_kb_main)" ;;
        *) tg_api_send "ℹ️ 未运行" "$chat_id" "$(tg_kb_main)" ;;
      esac
      ;;
    *)
      if [[ "$text" == /* ]]; then
        tg_api_send "未知命令。发送 /menu 打开菜单。" "$chat_id" "$(tg_kb_main)"
      else
        tg_api_send "请点选消息内按钮，或发送 /menu" "$chat_id" "$(tg_kb_main)"
      fi
      ;;
  esac
}

# 解析 getUpdates：输出
#   msg|<uid>|<chat_id>|<text>
#   cb|<uid>|<chat_id>|<msg_id>|<cb_id>|<data>
tg_parse_updates() {
  local json="$1"
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not data.get("ok"):
    sys.exit(0)
for u in data.get("result") or []:
    uid = u.get("update_id")
    if "callback_query" in u:
        cq = u["callback_query"]
        msg = cq.get("message") or {}
        chat = (msg.get("chat") or {})
        chat_id = chat.get("id")
        msg_id = msg.get("message_id") or 0
        cb_id = cq.get("id") or ""
        cdata = (cq.get("data") or "").replace("|", "/")
        if uid is None or chat_id is None:
            continue
        print(f"cb|{uid}|{chat_id}|{msg_id}|{cb_id}|{cdata}")
        continue
    msg = u.get("message") or u.get("edited_message") or {}
    chat = (msg.get("chat") or {})
    chat_id = chat.get("id")
    text = msg.get("text") or ""
    if uid is None or chat_id is None:
        continue
    text = text.replace("\n", " ").replace("|", "/")
    print(f"msg|{uid}|{chat_id}|{text}")
'
}

tg_load_offset() {
  if [[ -f "$TG_OFFSET_FILE" ]]; then
    cat "$TG_OFFSET_FILE"
  else
    echo "0"
  fi
}

tg_save_offset() {
  echo "$1" > "$TG_OFFSET_FILE"
}

tg_poll_once() {
  local timeout="${1:-25}"
  [[ "$TG_ENABLED" == "true" ]] || return 0
  [[ -n "$TG_BOT_TOKEN" ]] || return 0

  local offset
  offset="$(tg_load_offset)"
  local resp
  resp=$(curl -sS -m $((timeout + 10)) -X POST \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates" \
    --data-urlencode "offset=${offset}" \
    --data-urlencode "timeout=${timeout}" \
    --data-urlencode 'allowed_updates=["message","callback_query"]' 2>&1) || {
    log ERROR "getUpdates 失败: $resp"
    return 1
  }

  local line kind uid chat_id max_uid
  max_uid=$offset
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    kind="${line%%|*}"
    rest="${line#*|}"
    uid="${rest%%|*}"
    rest="${rest#*|}"
    case "$kind" in
      msg)
        chat_id="${rest%%|*}"
        text="${rest#*|}"
        log INFO "TG msg chat=$chat_id text=$text"
        tg_handle_message "$chat_id" "$text" || true
        ;;
      cb)
        chat_id="${rest%%|*}"
        rest="${rest#*|}"
        msg_id="${rest%%|*}"
        rest="${rest#*|}"
        cb_id="${rest%%|*}"
        data="${rest#*|}"
        tg_handle_callback "$chat_id" "$msg_id" "$cb_id" "$data" || true
        ;;
    esac
    if [[ "$uid" =~ ^[0-9]+$ ]] && (( uid + 1 > max_uid )); then
      max_uid=$((uid + 1))
    fi
  done < <(tg_parse_updates "$resp")

  if [[ "$max_uid" != "$offset" ]]; then
    tg_save_offset "$max_uid"
  fi
}

tg_test() {
  local msg
  msg="✅ <b>流量监控测试</b>
主机: <code>${HOSTNAME_TAG}</code>
时间: $(date '+%Y-%m-%d %H:%M:%S')
接口: <code>${INTERFACE}</code>
状态: 连通正常

已使用<strong>消息内按钮</strong>菜单（非常驻底部）。"
  tg_remove_reply_keyboard "$TG_CHAT_ID"
  tg_set_commands
  if tg_api_send "$msg" "$TG_CHAT_ID" "$(tg_kb_main)"; then
    echo "$(c_green "✓") Telegram 测试消息已发送（内联菜单）"
  else
    echo "$(c_red "✗") Telegram 发送失败，请检查 Token / Chat ID 与网络（日志: $LOG_FILE）"
  fi
}

menu_push_tg_menu() {
  if [[ "$TG_ENABLED" != "true" ]]; then
    echo "$(c_yellow "!") 请先启用 Telegram（菜单 → Telegram 配置）"
    return 0
  fi
  tg_set_commands
  tg_remove_reply_keyboard "$TG_CHAT_ID"
  if tg_api_send "$(tg_ui_main_text)" "$TG_CHAT_ID" "$(tg_kb_main)"; then
    echo "$(c_green "✓") 已推送 Telegram 内联主菜单"
    if ! is_daemon_running; then
      echo "$(c_yellow "!") 守护进程未运行：按钮需守护进程监听才会响应"
      echo "  执行: $SCRIPT_PATH --start"
    fi
  else
    echo "$(c_red "✗") 推送失败"
  fi
}

#-------------------------------------------------------------------------------
# 告警逻辑
#-------------------------------------------------------------------------------
# alerts.state 每行: day|scope|threshold|timestamp
# scope: daily / monthly

alert_already_sent() {
  local scope="$1" threshold="$2"
  local today
  today="$(date +%Y-%m-%d)"
  [[ -f "$ALERT_STATE_FILE" ]] || return 1
  local line last_ts now cooldown_sec
  line=$(grep -E "^${today}\|${scope}\|${threshold}\|" "$ALERT_STATE_FILE" 2>/dev/null | tail -1 || true)
  [[ -z "$line" ]] && return 1
  last_ts=$(echo "$line" | awk -F'|' '{print $4}')
  now=$(date +%s)
  cooldown_sec=$((ALERT_COOLDOWN_MIN * 60))
  if (( now - last_ts < cooldown_sec )); then
    return 0  # 已发送且在冷却中
  fi
  return 1
}

mark_alert_sent() {
  local scope="$1" threshold="$2"
  local today now
  today="$(date +%Y-%m-%d)"
  now=$(date +%s)
  ensure_dirs
  echo "${today}|${scope}|${threshold}|${now}" >> "$ALERT_STATE_FILE"
}

check_and_alert() {
  update_traffic
  load_state

  local day_used month_used day_limit_b month_limit_b day_p month_p
  day_used=$(mode_bytes "$day_rx" "$day_tx")
  month_used=$(mode_bytes "$month_rx" "$month_tx")
  day_limit_b=$(gb_to_bytes "$DAILY_LIMIT_GB")
  day_p=$(pct "$day_used" "$day_limit_b")

  local thr t
  IFS=',' read -ra thr <<< "$ALERT_THRESHOLDS"
  for t in "${thr[@]}"; do
    t=$(echo "$t" | tr -d ' ')
    [[ -z "$t" ]] && continue
    if awk -v p="$day_p" -v t="$t" 'BEGIN { exit !(p+0 >= t+0) }'; then
      if ! alert_already_sent "daily" "$t"; then
        send_threshold_alert "daily" "$t" "$day_used" "$day_limit_b" "$day_p"
        mark_alert_sent "daily" "$t"
      fi
    fi
  done

  if awk -v m="$MONTHLY_LIMIT_GB" 'BEGIN { exit !(m+0 > 0) }'; then
    month_limit_b=$(gb_to_bytes "$MONTHLY_LIMIT_GB")
    month_p=$(pct "$month_used" "$month_limit_b")
    for t in "${thr[@]}"; do
      t=$(echo "$t" | tr -d ' ')
      [[ -z "$t" ]] && continue
      if awk -v p="$month_p" -v t="$t" 'BEGIN { exit !(p+0 >= t+0) }'; then
        if ! alert_already_sent "monthly" "$t"; then
          send_threshold_alert "monthly" "$t" "$month_used" "$month_limit_b" "$month_p"
          mark_alert_sent "monthly" "$t"
        fi
      fi
    done
  fi
}

send_threshold_alert() {
  local scope="$1" threshold="$2" used="$3" limit_b="$4" percent="$5"
  local scope_cn icon remain remain_gb
  if [[ "$scope" == "daily" ]]; then
    scope_cn="日流量"
  else
    scope_cn="月流量"
  fi
  if awk -v p="$percent" 'BEGIN { exit !(p >= 100) }'; then
    icon="🚨"
  elif awk -v p="$percent" 'BEGIN { exit !(p >= 90) }'; then
    icon="⚠️"
  else
    icon="📊"
  fi
  remain=$((limit_b - used))
  (( remain < 0 )) && remain=0
  remain_gb=$(bytes_to_gb "$remain")

  local msg
  msg="${icon} <b>${scope_cn}告警 ${threshold}%</b>
主机: <code>${HOSTNAME_TAG}</code>
接口: <code>${INTERFACE}</code> | 统计: <code>${COUNT_MODE}</code>
已用: <b>$(fmt_bytes "$used")</b> / $(fmt_bytes "$limit_b") (<b>${percent}%</b>)
剩余: ${remain_gb} GB
时间: $(date '+%Y-%m-%d %H:%M:%S')"

  if awk -v p="$percent" 'BEGIN { exit !(p >= 100) }'; then
    msg+=$'\n\n'"🛑 <b>已达/超过限额，请立即处理，避免服务被终止！</b>"
  fi

  log WARN "${scope_cn} 达到 ${threshold}%: used=$(fmt_bytes "$used") percent=${percent}%"
  tg_send "$msg" || true
}

send_status_report() {
  update_traffic
  load_state
  local day_used month_used day_limit_b day_p remain remain_gb
  day_used=$(mode_bytes "$day_rx" "$day_tx")
  month_used=$(mode_bytes "$month_rx" "$month_tx")
  day_limit_b=$(gb_to_bytes "$DAILY_LIMIT_GB")
  day_p=$(pct "$day_used" "$day_limit_b")
  remain=$((day_limit_b - day_used))
  (( remain < 0 )) && remain=0
  remain_gb=$(bytes_to_gb "$remain")

  local month_line=""
  if awk -v m="$MONTHLY_LIMIT_GB" 'BEGIN { exit !(m+0 > 0) }'; then
    local ml mp
    ml=$(gb_to_bytes "$MONTHLY_LIMIT_GB")
    mp=$(pct "$month_used" "$ml")
    month_line=$'\n'"月用量: $(fmt_bytes "$month_used") / $(fmt_bytes "$ml") (${mp}%)"
  else
    month_line=$'\n'"月用量: $(fmt_bytes "$month_used")（未设月限额）"
  fi

  local msg
  msg="📡 <b>流量使用报告</b>
主机: <code>${HOSTNAME_TAG}</code>
接口: <code>${INTERFACE}</code> | 模式: <code>${COUNT_MODE}</code>
日期: $(date +%Y-%m-%d)

日用量: <b>$(fmt_bytes "$day_used")</b> / $(fmt_bytes "$day_limit_b") (<b>${day_p}%</b>)
剩余: <b>${remain_gb} GB</b>
  RX: $(fmt_bytes "$day_rx")
  TX: $(fmt_bytes "$day_tx")${month_line}

更新: $(date '+%Y-%m-%d %H:%M:%S')"

  tg_send "$msg" "HTML" "true"
}

#-------------------------------------------------------------------------------
# 状态展示
#-------------------------------------------------------------------------------
show_status() {
  update_traffic
  load_state

  local day_used month_used day_limit_b day_p remain remain_gb
  day_used=$(mode_bytes "$day_rx" "$day_tx")
  month_used=$(mode_bytes "$month_rx" "$month_tx")
  day_limit_b=$(gb_to_bytes "$DAILY_LIMIT_GB")
  day_p=$(pct "$day_used" "$day_limit_b")
  remain=$((day_limit_b - day_used))
  (( remain < 0 )) && remain=0
  remain_gb=$(bytes_to_gb "$remain")

  echo ""
  echo "$(c_bold "════════════ 流量监控状态 ════════════")"
  echo "  主机:     ${HOSTNAME_TAG}"
  echo "  接口:     ${INTERFACE}"
  echo "  统计模式: ${COUNT_MODE}  (total=上下行合计, rx=下载, tx=上传)"
  echo "  日期:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo ""
  echo "$(c_cyan "── 今日流量 ──")"
  echo "  已用: $(c_bold "$(fmt_bytes "$day_used")")  /  限额 $(fmt_bytes "$day_limit_b") (${DAILY_LIMIT_GB} GB)"
  echo "  占比: $(progress_bar "$day_p")"
  echo "  剩余: $(c_green "${remain_gb} GB")"
  echo "  ├ 下载(RX): $(fmt_bytes "$day_rx")"
  echo "  └ 上传(TX): $(fmt_bytes "$day_tx")"
  echo ""
  echo "$(c_cyan "── 本月流量 ──")"
  if awk -v m="$MONTHLY_LIMIT_GB" 'BEGIN { exit !(m+0 > 0) }'; then
    local ml mp
    ml=$(gb_to_bytes "$MONTHLY_LIMIT_GB")
    mp=$(pct "$month_used" "$ml")
    echo "  已用: $(fmt_bytes "$month_used") / $(fmt_bytes "$ml") (${MONTHLY_LIMIT_GB} GB)"
    echo "  占比: $(progress_bar "$mp")"
  else
    echo "  已用: $(fmt_bytes "$month_used")  (未设置月限额)"
  fi
  echo "  ├ 下载(RX): $(fmt_bytes "$month_rx")"
  echo "  └ 上传(TX): $(fmt_bytes "$month_tx")"
  echo ""
  echo "$(c_cyan "── 告警 / Telegram ──")"
  echo "  TG 启用:  ${TG_ENABLED}"
  echo "  阈值(%):  ${ALERT_THRESHOLDS}"
  echo "  冷却:     ${ALERT_COOLDOWN_MIN} 分钟"
  echo "  检查间隔: ${CHECK_INTERVAL_SEC} 秒（守护模式）"
  if is_daemon_running; then
    echo "  守护进程: $(c_green "运行中") (PID $(cat "$PID_FILE"))"
  else
    echo "  守护进程: $(c_yellow "未运行")"
  fi
  if has_cron; then
    echo "  定时任务: $(c_green "已安装")"
  else
    echo "  定时任务: $(c_yellow "未安装")"
  fi
  echo "$(c_bold "══════════════════════════════════════")"
  echo ""
}

#-------------------------------------------------------------------------------
# 守护进程 / Cron
#-------------------------------------------------------------------------------
is_daemon_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

daemon_loop() {
  ensure_dirs
  export IN_DAEMON=1
  echo $$ > "$PID_FILE"
  log INFO "守护进程启动 PID=$$ interval=${CHECK_INTERVAL_SEC}s tg=${TG_ENABLED}"
  trap 'log INFO "守护进程退出"; rm -f "$PID_FILE"; exit 0' INT TERM

  # 启动时注册 bot 命令
  if [[ "$TG_ENABLED" == "true" ]]; then
    tg_set_commands
  fi

  local last_check=0 now
  last_check=0

  while true; do
    now=$(date +%s)
    if (( now - last_check >= CHECK_INTERVAL_SEC )); then
      check_and_alert || log ERROR "check_and_alert 执行失败"
      last_check=$now
    fi

    if [[ "$TG_ENABLED" == "true" && -n "$TG_BOT_TOKEN" ]]; then
      # long-poll 处理 TG 菜单；失败则短睡避免狂刷
      tg_poll_once 25 || sleep 5
    else
      # 无 TG 时按剩余间隔休眠
      local sleep_sec=$(( CHECK_INTERVAL_SEC - (now - last_check) ))
      (( sleep_sec < 1 )) && sleep_sec=1
      (( sleep_sec > CHECK_INTERVAL_SEC )) && sleep_sec=$CHECK_INTERVAL_SEC
      sleep "$sleep_sec"
    fi
  done
}

start_daemon() {
  if is_daemon_running; then
    echo "$(c_yellow "!") 守护进程已在运行 (PID $(cat "$PID_FILE"))"
    return 0
  fi
  nohup bash "$SCRIPT_PATH" --daemon >> "$LOG_FILE" 2>&1 &
  sleep 0.5
  if is_daemon_running; then
    echo "$(c_green "✓") 守护进程已启动 (PID $(cat "$PID_FILE"))"
    echo "  提示: 已启用 TG 时，守护进程会同时监听 Telegram 菜单指令"
    log INFO "用户启动守护进程"
  else
    echo "$(c_red "✗") 启动失败，请查看 $LOG_FILE"
  fi
}

stop_daemon() {
  if ! is_daemon_running; then
    echo "$(c_yellow "!") 守护进程未运行"
    rm -f "$PID_FILE"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null || true
  sleep 0.5
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  echo "$(c_green "✓") 守护进程已停止"
  log INFO "用户停止守护进程 PID=$pid"
}

has_cron() {
  crontab -l 2>/dev/null | grep -qF "$CRON_TAG"
}

install_cron() {
  local interval_min="${1:-5}"
  # 至少 1 分钟
  (( interval_min < 1 )) && interval_min=1
  local line
  line="*/${interval_min} * * * * $SCRIPT_PATH --check # ${CRON_TAG}"

  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -vF "$CRON_TAG" > "$tmp" || true
  echo "$line" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  echo "$(c_green "✓") 已安装 crontab: 每 ${interval_min} 分钟检查一次"
  log INFO "安装 cron 每 ${interval_min} 分钟"
}

install_cron_report() {
  # 每天固定时间发报告，默认 09:00 和 21:00
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -vF "${CRON_TAG}-report" > "$tmp" || true
  echo "0 9,21 * * * $SCRIPT_PATH --report # ${CRON_TAG}-report" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  echo "$(c_green "✓") 已安装日报: 每天 09:00 与 21:00 推送流量报告"
}

remove_cron() {
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -vF "$CRON_TAG" > "$tmp" || true
  if [[ -s "$tmp" ]]; then
    crontab "$tmp"
  else
    crontab -r 2>/dev/null || true
  fi
  rm -f "$tmp"
  echo "$(c_green "✓") 已移除相关 crontab"
  log INFO "移除 cron"
}

#-------------------------------------------------------------------------------
# 交互式选择：方向键 / j-k / 数字 / 回车
#-------------------------------------------------------------------------------
# 读一个按键，输出: UP DOWN ENTER QUIT NUM0-9 CHAR... ESC
read_key() {
  local k1 k2 k3
  # 关闭回显与规范模式（调用方负责恢复）
  IFS= read -rsn1 k1 || return 1
  if [[ "$k1" == $'\x1b' ]]; then
    # 方向键: ESC [ A/B/C/D
    IFS= read -rsn1 -t 0.05 k2 || { echo ESC; return 0; }
    if [[ "$k2" == "[" ]]; then
      IFS= read -rsn1 -t 0.05 k3 || { echo ESC; return 0; }
      case "$k3" in
        A) echo UP; return 0 ;;
        B) echo DOWN; return 0 ;;
        C) echo RIGHT; return 0 ;;
        D) echo LEFT; return 0 ;;
        H) echo HOME; return 0 ;;
        F) echo END; return 0 ;;
      esac
      # 可能是 PageUp/PageDown 等三字节后还有 ~
      echo OTHER
      return 0
    fi
    echo ESC
    return 0
  fi
  case "$k1" in
    "")          echo ENTER ;;   # 某些终端 Enter 为空
    $'\n'|$'\r') echo ENTER ;;
    j|J)         echo DOWN ;;
    k|K)         echo UP ;;
    q|Q)         echo QUIT ;;
    [0-9])       echo "NUM$k1" ;;
    *)           echo "CHAR$k1" ;;
  esac
}

# 交互选择菜单
# 用法: menu_select "标题" "选项1" "选项2" ...
# 成功时: MENU_RESULT=选中下标(0-based), 返回 0
# 取消:   MENU_RESULT=-1, 返回 1
# 非 TTY 时回退到编号输入
menu_select() {
  local title="$1"; shift
  local options=("$@")
  local count=${#options[@]}
  local selected=0
  local i key

  if (( count == 0 )); then
    MENU_RESULT=-1
    return 1
  fi

  # 非交互终端：编号回退
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo ""
    echo "$(c_bold "$title")"
    for ((i=0; i<count; i++)); do
      printf "  %d) %s\n" "$((i+1))" "${options[$i]}"
    done
    local raw
    read -r -p "请选择 [1-${count}]: " raw || true
    if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= 1 && raw <= count )); then
      MENU_RESULT=$((raw - 1))
      return 0
    fi
    MENU_RESULT=-1
    return 1
  fi

  # 保存终端设置并清理
  local old_stty
  old_stty=$(stty -g 2>/dev/null || true)
  tput civis 2>/dev/null || true
  stty -echo -icanon time 0 min 0 2>/dev/null || stty -echo 2>/dev/null || true

  cleanup_menu() {
    tput cnorm 2>/dev/null || true
    [[ -n "${old_stty:-}" ]] && stty "$old_stty" 2>/dev/null || stty echo icanon 2>/dev/null || true
  }
  trap cleanup_menu RETURN

  # 首次绘制前打印标题
  echo ""
  echo "$(c_bold "$title")"
  echo "$(c_cyan "  ↑/↓ 或 j/k 移动  ·  回车确认  ·  数字快捷  ·  q 取消")"
  echo ""

  # 为菜单行预留空间
  for ((i=0; i<count; i++)); do
    echo ""
  done
  # 光标移回菜单起始行
  printf "\033[%dA" "$count"

  draw_options() {
    local idx
    for ((idx=0; idx<count; idx++)); do
      # 清行再画
      printf "\033[2K\r"
      if (( idx == selected )); then
        printf "  %s %s\n" "$(c_green "▸")" "$(c_rev " ${options[$idx]} ")"
      else
        printf "    %s\n" "${options[$idx]}"
      fi
    done
    # 回到顶部
    printf "\033[%dA" "$count"
  }

  draw_options

  # min 1 阻塞读
  stty -echo -icanon time 0 min 1 2>/dev/null || true

  while true; do
    key="$(read_key)" || key="QUIT"
    case "$key" in
      UP)
        selected=$(( (selected - 1 + count) % count ))
        draw_options
        ;;
      DOWN)
        selected=$(( (selected + 1) % count ))
        draw_options
        ;;
      HOME)
        selected=0
        draw_options
        ;;
      END)
        selected=$((count - 1))
        draw_options
        ;;
      ENTER)
        # 离开菜单区：向下跳过选项行
        printf "\033[%dB" "$count"
        echo ""
        cleanup_menu
        trap - RETURN
        MENU_RESULT=$selected
        return 0
        ;;
      QUIT|ESC)
        printf "\033[%dB" "$count"
        echo ""
        cleanup_menu
        trap - RETURN
        MENU_RESULT=-1
        return 1
        ;;
      NUM*)
        local num="${key#NUM}"
        # 菜单超过 9 项时，短暂等待第二位数字（如 10、11）
        if (( count > 9 )) && [[ "$num" != "0" ]]; then
          local d2=""
          IFS= read -rsn1 -t 0.45 d2 2>/dev/null || true
          if [[ "$d2" =~ ^[0-9]$ ]]; then
            num="${num}${d2}"
          fi
        fi
        # 1-based；0 表示退出/返回/取消项
        if [[ "$num" == "0" ]]; then
          local found=-1
          for ((i=0; i<count; i++)); do
            if [[ "${options[$i]}" =~ (退出|返回|取消) ]]; then
              found=$i
              break
            fi
          done
          if (( found >= 0 )); then
            selected=$found
          else
            selected=$((count - 1))
          fi
          draw_options
          printf "\033[%dB" "$count"
          echo ""
          cleanup_menu
          trap - RETURN
          MENU_RESULT=$selected
          return 0
        elif [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= count )); then
          selected=$((num - 1))
          draw_options
          printf "\033[%dB" "$count"
          echo ""
          cleanup_menu
          trap - RETURN
          MENU_RESULT=$selected
          return 0
        fi
        ;;
    esac
  done
}

prompt_input() {
  local prompt="$1" default="$2" var
  # 确保输入时终端正常
  stty echo icanon 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " var || true
    echo "${var:-$default}"
  else
    read -r -p "$prompt: " var || true
    echo "$var"
  fi
}

menu_config_basic() {
  echo ""
  echo "$(c_bold "—— 基础配置 ——")"
  echo "当前网卡列表:"
  list_interfaces | sed 's/^/  - /'
  echo "  - all  (汇总全部，建议生产用 eth0 等外网口)"
  INTERFACE=$(prompt_input "监控网卡" "$INTERFACE")
  DAILY_LIMIT_GB=$(prompt_input "每日限额 (GB)" "$DAILY_LIMIT_GB")
  MONTHLY_LIMIT_GB=$(prompt_input "每月限额 (GB, 0=不限)" "$MONTHLY_LIMIT_GB")
  echo "统计模式: total=上下行合计 | rx=仅下载 | tx=仅上传"
  COUNT_MODE=$(prompt_input "统计模式" "$COUNT_MODE")
  ALERT_THRESHOLDS=$(prompt_input "告警阈值% (逗号分隔)" "$ALERT_THRESHOLDS")
  ALERT_COOLDOWN_MIN=$(prompt_input "告警冷却(分钟)" "$ALERT_COOLDOWN_MIN")
  CHECK_INTERVAL_SEC=$(prompt_input "守护检查间隔(秒)" "$CHECK_INTERVAL_SEC")
  HOSTNAME_TAG=$(prompt_input "主机标识(显示在TG)" "$HOSTNAME_TAG")
  save_config
  echo "$(c_green "✓") 基础配置已保存"
}

menu_config_tg() {
  echo ""
  echo "$(c_bold "—— Telegram 配置 ——")"
  echo "1) 在 Telegram 找 @BotFather 创建 Bot，获得 Token"
  echo "2) 把 Bot 拉进群或私聊，获取 Chat ID"
  echo "   私聊可用 @userinfobot；群可把 bot 加进群后访问:"
  echo "   https://api.telegram.org/bot<Token>/getUpdates"
  echo "3) 配置完成后启动守护进程，即可用 TG 内联菜单遥控/改配置"
  echo ""
  TG_BOT_TOKEN=$(prompt_input "Bot Token" "$TG_BOT_TOKEN")
  TG_CHAT_ID=$(prompt_input "Chat ID" "$TG_CHAT_ID")
  local en
  en=$(prompt_input "启用 Telegram? (true/false)" "$TG_ENABLED")
  TG_ENABLED="$en"
  save_config
  echo "$(c_green "✓") Telegram 配置已保存"
  local t
  t=$(prompt_input "现在发送测试消息并推送内联菜单? (y/N)" "N")
  if [[ "$t" =~ ^[Yy]$ ]]; then
    TG_ENABLED="true"
    tg_test
  fi
}

# 一键安装后的交互配置向导（也可随时 --setup）
setup_wizard() {
  echo ""
  echo "$(c_bold "╔══════════════════════════════════════╗")"
  echo "$(c_bold "║     流量监控 · 首次配置向导          ║")"
  echo "$(c_bold "╚══════════════════════════════════════╝")"
  echo "按提示填写；直接回车保留方括号内默认值。"
  echo ""

  menu_config_basic
  menu_config_tg

  echo ""
  local items=(
    "启动守护进程（推荐：后台监控 + TG 菜单）"
    "仅安装 crontab 每 5 分钟检查"
    "稍后手动启动"
  )
  if menu_select "—— 如何运行监控？——" "${items[@]}"; then
    case "$MENU_RESULT" in
      0)
        start_daemon
        if [[ "$TG_ENABLED" == "true" ]]; then
          menu_push_tg_menu || true
        fi
        ;;
      1)
        install_cron 5
        ;;
      *)
        echo "稍后可执行: $SCRIPT_PATH --start"
        ;;
    esac
  fi

  echo ""
  echo "$(c_green "✓") 配置向导完成"
  echo "  配置文件: $CONFIG_FILE"
  echo "  查看状态: $SCRIPT_PATH --status"
  echo "  打开菜单: $SCRIPT_PATH"
  if [[ "$TG_ENABLED" == "true" ]]; then
    echo "  Telegram: 向 Bot 发送 /menu"
  fi
  echo ""
}

menu_schedule() {
  local items=(
    "启动后台守护进程 (推荐，含 TG 菜单监听)"
    "停止后台守护进程"
    "安装 crontab 定时检查 (每 N 分钟)"
    "安装每日 TG 报告 (09:00 / 21:00)"
    "移除全部 crontab"
    "返回上级"
  )
  if ! menu_select "—— 调度方式 ——" "${items[@]}"; then
    return 0
  fi
  case "$MENU_RESULT" in
    0) start_daemon ;;
    1) stop_daemon ;;
    2)
      local m
      m=$(prompt_input "检查间隔(分钟)" "5")
      install_cron "$m"
      ;;
    3) install_cron_report ;;
    4) remove_cron ;;
    *) ;;
  esac
}

menu_reset_day() {
  local items=("确认清零今日累计" "取消")
  if ! menu_select "—— 清零今日流量 ——" "${items[@]}"; then
    return 0
  fi
  if (( MENU_RESULT == 0 )); then
    update_traffic
    load_state
    day_rx=0
    day_tx=0
    save_state
    : > "$ALERT_STATE_FILE" 2>/dev/null || true
    echo "$(c_green "✓") 今日累计已清零"
    log WARN "用户清零今日流量"
  else
    echo "已取消"
  fi
}

main_menu() {
  local items=(
    "查看当前状态"
    "立即检查并告警"
    "推送状态报告到 Telegram"
    "基础配置 (网卡/限额/阈值)"
    "Telegram 配置 / 测试"
    "推送 TG 内联主菜单"
    "调度 (守护进程 / Cron)"
    "查看日志 (最近 40 行)"
    "清零今日累计"
    "重新加载配置并显示"
    "退出"
  )

  while true; do
    echo ""
    echo "$(c_bold "╔════════════════════════════════════╗")"
    echo "$(c_bold "║     流量监控 · Traffic Monitor     ║")"
    echo "$(c_bold "╚════════════════════════════════════╝")"

    if ! menu_select "请选择功能" "${items[@]}"; then
      echo "再见。"
      exit 0
    fi

    case "$MENU_RESULT" in
      0) show_status ;;
      1)
        check_and_alert
        show_status
        echo "$(c_green "✓") 检查完成"
        ;;
      2)
        if send_status_report; then
          echo "$(c_green "✓") 报告已推送"
        else
          echo "$(c_red "✗") 推送失败（请先配置并启用 TG）"
        fi
        ;;
      3) menu_config_basic ;;
      4) menu_config_tg ;;
      5) menu_push_tg_menu ;;
      6) menu_schedule ;;
      7)
        echo "$(c_cyan "—— 最近日志 ——")"
        tail -n 40 "$LOG_FILE" 2>/dev/null || echo "(无日志)"
        ;;
      8) menu_reset_day ;;
      9)
        load_config
        show_status
        ;;
      10)
        echo "再见。"
        exit 0
        ;;
      *)
        echo "$(c_yellow "!") 无效选项"
        ;;
    esac
  done
}

#-------------------------------------------------------------------------------
# CLI 用法
#-------------------------------------------------------------------------------
usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

不带参数: 进入交互菜单（↑/↓ 选择，回车确认）

选项:
  --status, -s       显示流量状态
  --check, -c        更新用量并检查阈值告警
  --report, -r       推送状态报告到 Telegram
  --daemon           以前台守护循环运行（含 TG 菜单轮询）
  --start            后台启动守护进程
  --stop             停止守护进程
  --install-cron [N] 安装 crontab，每 N 分钟检查 (默认 5)
  --install-report   安装每日 09:00/21:00 TG 报告
  --remove-cron      移除相关 crontab
  --setup            首次/重新交互配置向导（推荐新装使用）
  --test-tg          发送 Telegram 测试消息（内联菜单）
  --push-menu        向 TG 推送内联主菜单
  --config           进入配置向导（基础+TG）
  --reset-day        清零今日累计
  --help, -h         显示帮助

Telegram 内联菜单（需启用 TG 并运行守护进程）:
  /menu /start  主菜单（消息内按钮，非常驻底部）
  /config       配置中心（网卡/限额/阈值/标识…）
  /status       流量状态
  配置中心可对话式修改全部监控参数、调度与清零

配置文件: $CONFIG_FILE
状态目录: $STATE_DIR
日志文件: $LOG_FILE

示例:
  $0                  # 终端交互菜单（方向键选择）
  $0 --status         # 看一眼用量
  $0 --check          # cron 调用
  $0 --start          # 后台监控 + TG 菜单监听
  $0 --push-menu      # 推送 TG 内联主菜单
  $0 --install-cron 5 # 每 5 分钟检查
EOF
}

#-------------------------------------------------------------------------------
# 入口
#-------------------------------------------------------------------------------
main() {
  ensure_dirs
  load_config

  # 无配置时写一份默认，方便编辑
  if [[ ! -f "$CONFIG_FILE" ]]; then
    save_config
  fi

  local cmd="${1:-}"
  case "$cmd" in
    "" )
      # 全新环境且交互终端：直接进向导
      if [[ -t 0 && -t 1 && -z "${TG_BOT_TOKEN:-}" && ! -f "${STATE_DIR}/.setup_done" ]]; then
        setup_wizard
        touch "${STATE_DIR}/.setup_done"
      fi
      main_menu
      ;;
    --setup|--install-wizard)
      setup_wizard
      touch "${STATE_DIR}/.setup_done"
      ;;
    --status|-s)
      show_status
      ;;
    --check|-c)
      check_and_alert
      ;;
    --report|-r)
      send_status_report
      ;;
    --daemon)
      daemon_loop
      ;;
    --start)
      start_daemon
      ;;
    --stop)
      stop_daemon
      ;;
    --install-cron)
      install_cron "${2:-5}"
      ;;
    --install-report)
      install_cron_report
      ;;
    --remove-cron)
      remove_cron
      ;;
    --test-tg)
      tg_test
      ;;
    --push-menu)
      menu_push_tg_menu
      ;;
    --config)
      menu_config_basic
      menu_config_tg
      ;;
    --reset-day)
      update_traffic
      load_state
      day_rx=0
      day_tx=0
      save_state
      : > "$ALERT_STATE_FILE" 2>/dev/null || true
      echo "今日累计已清零"
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "未知选项: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
