#!/usr/bin/env bash
#
# 夜莺(Nightingale)一体化部署脚本  —— 母鸡 / 节点 共用一个脚本
#
# 用法:
#   母鸡(中心服务端,装一次):
#     sudo ./n9e-deploy.sh master
#     # 装完会自动打印「节点该执行的命令」,IP 已填好,复制到节点上跑即可
#
#   节点(被监控机器,每台一次):
#     sudo ./n9e-deploy.sh node <母鸡IP>
#     # 或:  N9E_SERVER=<母鸡IP> sudo ./n9e-deploy.sh node
#
#   不带参数运行会自动判断 / 交互询问角色:
#     sudo ./n9e-deploy.sh
#
#   卸载(自动识别本机装的是母鸡还是节点):
#     sudo ./n9e-deploy.sh uninstall            # 仅删程序与服务,保留数据
#     sudo ./n9e-deploy.sh uninstall master     # 只卸母鸡
#     sudo ./n9e-deploy.sh uninstall node       # 只卸节点
#     PURGE_DATA=1 sudo ./n9e-deploy.sh uninstall   # 连数据目录一起删除
#
# 特点:母鸡端纯二进制(n9e 用 SQLite+内置 miniredis,VictoriaMetrics 存指标),
#       无需 Docker / MySQL / Redis;节点端只装 Categraf 采集器。
#
set -euo pipefail

# ===================== 可调参数 =====================
# --- 母鸡(master)相关 ---
N9E_DIR="${N9E_DIR:-/opt/n9e}"
VM_DIR="${VM_DIR:-/opt/victoria-metrics}"
N9E_PORT="${N9E_PORT:-17000}"
VM_PORT="${VM_PORT:-8428}"
RETENTION="${RETENTION:-1d}"                    # 时序数据保留期: 1d/3d/7d/1m...
N9E_VERSION="${N9E_VERSION:-v8.2.0}"            # 夜莺版本(必须 v8+ 才默认 sqlite+miniredis)
# 注意:VictoriaMetrics 的 v1.136.x / v1.122.x 是「企业版 LTS」,没有社区版单机包!
# 必须用「主线社区版」(文件名不带 -enterprise),下面这个已实测存在。
VM_VERSION="${VM_VERSION:-v1.135.0}"

# --- 节点(node)相关 ---
CATEGRAF_DIR="${CATEGRAF_DIR:-/opt/categraf}"
CATEGRAF_VERSION="${CATEGRAF_VERSION:-}"        # 留空自动取最新
N9E_SERVER="${N9E_SERVER:-}"                    # 母鸡 IP(node 模式必填)
# ===================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*" >&2; }

# ---------- 通用检查 ----------
[ "$(id -u)" -eq 0 ] || { error "请用 root 权限执行 (sudo ...)"; exit 1; }
for c in curl tar; do command -v $c >/dev/null 2>&1 || { error "缺少命令 $c,请先安装"; exit 1; }; done
case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) error "暂不支持的架构: $(uname -m)"; exit 1 ;;
esac

# 探测本机第一个对外 IPv4(供 master 打印节点命令用)
detect_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# ---------- 解析角色 ----------
ROLE="${1:-}"
case "$ROLE" in
    master|node) shift ;;
    uninstall)   shift; UNINST_TARGET="${1:-auto}" ;;
    "")          ROLE="" ;;
    *)           error "未知角色 '$ROLE'。用法: $0 [master|node|uninstall] [参数]"; exit 1 ;;
esac
# node 模式:母鸡 IP 可由第 2 个参数提供
if [ "$ROLE" = "node" ] && [ -n "${1:-}" ] && [ -z "$N9E_SERVER" ]; then
    N9E_SERVER="$1"
fi

# 未显式指定角色时自动判断
if [ -z "$ROLE" ]; then
    if [ -n "$N9E_SERVER" ]; then
        ROLE="node"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^n9e\.service' \
         || ss -tlnp 2>/dev/null | grep -q ":${N9E_PORT} "; then
        ROLE="master"; warn "检测到本机已部署夜莺,按 master(母鸡)重新部署"
    elif [ -t 0 ]; then
        echo; echo "这台机器要部署成哪种角色?"
        echo "  1) 母鸡 master  —— 中心服务端(装一次)"
        echo "  2) 节点 node    —— 被监控机器(接入采集)"
        read -rp "请输入 1 或 2: " ans
        case "$ans" in
            1) ROLE="master" ;;
            2) ROLE="node"
               read -rp "请输入母鸡(夜莺)IP: " N9E_SERVER ;;
            *) error "无效输入"; exit 1 ;;
        esac
    else
        error "无法判断角色。请显式指定: $0 master  或  $0 node <母鸡IP>"; exit 1
    fi
fi

############################################################
# 角色:master(母鸡)
############################################################
deploy_master() {
    info "角色: 母鸡(master);架构: ${ARCH};保留期: ${RETENTION}"
    case "$N9E_VERSION" in v8*|v9*|v1[0-9]*) ;; *) warn "${N9E_VERSION} 可能非 v8+,只有 v8+ 默认 sqlite+miniredis";; esac
    info "夜莺版本: ${N9E_VERSION};时序库版本: ${VM_VERSION}"

    local TMP; TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN; cd "$TMP"

    # 1) VictoriaMetrics(时序库)
    local VM_TAR="victoria-metrics-linux-${ARCH}-${VM_VERSION}.tar.gz"
    info "下载 VictoriaMetrics (${VM_TAR}) ..."
    curl -fSL -o "$VM_TAR" "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/${VM_TAR}" \
        || { error "VictoriaMetrics 下载失败(注意别用 v1.136.x 这种企业版 LTS)"; exit 1; }
    mkdir -p "$VM_DIR/data"; tar xf "$VM_TAR" -C "$VM_DIR"
    local VM_BIN; VM_BIN=$(find "$VM_DIR" -maxdepth 1 -name "victoria-metrics-prod" | head -n1)
    [ -n "$VM_BIN" ] || { error "未找到 victoria-metrics-prod"; exit 1; }
    chmod +x "$VM_BIN"

    # 2) n9e(夜莺)
    local N9E_TAR="n9e-${N9E_VERSION}-linux-${ARCH}.tar.gz"
    info "下载夜莺 (${N9E_TAR}) ..."
    if ! curl -fSL -o "$N9E_TAR" "https://download.flashcat.cloud/${N9E_TAR}" 2>/dev/null; then
        warn "国内下载站失败,改用 github..."
        curl -fSL -o "$N9E_TAR" "https://github.com/ccfos/nightingale/releases/download/${N9E_VERSION}/${N9E_TAR}" \
            || { error "夜莺下载失败"; exit 1; }
    fi
    mkdir -p "$N9E_DIR"; tar xf "$N9E_TAR" -C "$N9E_DIR"
    if [ ! -f "$N9E_DIR/n9e" ]; then
        local inner; inner=$(find "$N9E_DIR" -maxdepth 2 -name n9e -type f | head -n1)
        [ -n "$inner" ] && cp -rf "$(dirname "$inner")"/* "$N9E_DIR"/
    fi
    [ -f "$N9E_DIR/n9e" ] || { error "未找到 n9e 二进制"; exit 1; }
    chmod +x "$N9E_DIR/n9e"

    local CONF="$N9E_DIR/etc/config.toml"
    [ -f "$CONF" ] || { error "未找到 ${CONF}"; exit 1; }
    if ! grep -Eq '^\s*\[\[Pushgw\.Writers\]\]' "$CONF"; then
        cat >> "$CONF" <<EOF

# —— 安装脚本追加:指标写入本地 VictoriaMetrics ——
[[Pushgw.Writers]]
Url = "http://127.0.0.1:${VM_PORT}/api/v1/write"
EOF
        info "已配置 Pushgw.Writers -> 127.0.0.1:${VM_PORT}"
    fi

    # 3) systemd
    cat > /etc/systemd/system/victoria-metrics.service <<EOF
[Unit]
Description=VictoriaMetrics (TSDB for Nightingale)
After=network.target
[Service]
Type=simple
ExecStart=${VM_BIN} -storageDataPath=${VM_DIR}/data -retentionPeriod=${RETENTION} -httpListenAddr=:${VM_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/n9e.service <<EOF
[Unit]
Description=Nightingale (n9e) Server
After=network.target victoria-metrics.service
[Service]
Type=simple
ExecStart=${N9E_DIR}/n9e
WorkingDirectory=${N9E_DIR}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable victoria-metrics n9e >/dev/null 2>&1 || true
    systemctl restart victoria-metrics; sleep 2; systemctl restart n9e

    info "等待服务就绪..."
    for i in $(seq 1 30); do curl -s "http://127.0.0.1:${N9E_PORT}" >/dev/null 2>&1 && break; sleep 2; done

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${N9E_PORT}/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "firewalld 已放行 ${N9E_PORT}/tcp"
    fi

    local HOST_IP; HOST_IP=$(detect_ip); [ -n "$HOST_IP" ] || HOST_IP="母鸡IP"
    local SELF; SELF=$(basename "$0")

    echo
    if systemctl is-active --quiet n9e && systemctl is-active --quiet victoria-metrics; then
        info  "============================================================"
        info  " 母鸡部署完成!(无 MySQL / Redis / Docker)"
        info  "   访问 : http://${HOST_IP}:${N9E_PORT}   账号 root / 密码 root.2020"
        info  "   存储 : SQLite + 内置 miniredis;时序库 VictoriaMetrics 保留 ${RETENTION}"
        info  "============================================================"
        echo -e "${BLUE} 节点接入:把本脚本拷到每台被监控机器,执行:${NC}"
        echo -e "${BLUE}     sudo bash ${SELF} node ${HOST_IP}${NC}"
        echo
        echo -e "${BLUE} 拷脚本到节点的示例(scp):${NC}"
        echo -e "${BLUE}     scp ${SELF} root@节点IP:/root/${NC}"
        echo
        echo -e "${BLUE} 想让母鸡自己也被监控,在母鸡上再跑一次:${NC}"
        echo -e "${BLUE}     sudo bash ${SELF} node 127.0.0.1${NC}"
        warn  "云服务器记得在安全组放行 TCP ${N9E_PORT}。"
        warn  "若 ${HOST_IP} 是内网地址而节点在外网,请把上面命令里的 IP 换成母鸡的公网地址。"
    else
        error "启动异常,请查看: journalctl -u n9e -n 50 ; journalctl -u victoria-metrics -n 50"; exit 1
    fi
}

############################################################
# 角色:node(节点)
############################################################
deploy_node() {
    [ -n "$N9E_SERVER" ] || { error "node 模式需要母鸡IP。用法: sudo $0 node <母鸡IP>"; exit 1; }
    info "角色: 节点(node);架构: ${ARCH};母鸡: ${N9E_SERVER}:${N9E_PORT}"

    # 1) 取 categraf 版本
    if [ -z "$CATEGRAF_VERSION" ]; then
        CATEGRAF_VERSION=$(curl -fsSL https://api.github.com/repos/flashcatcloud/categraf/releases/latest 2>/dev/null \
            | grep -oP '"tag_name":\s*"\K[^"]+' || true)
        [ -n "$CATEGRAF_VERSION" ] || CATEGRAF_VERSION="v0.4.10"
    fi
    local VER="${CATEGRAF_VERSION#v}"
    local TARBALL="categraf-v${VER}-linux-${ARCH}.tar.gz"
    info "安装 Categraf ${CATEGRAF_VERSION}"

    local TMP; TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN; cd "$TMP"
    if ! curl -fSL -o "$TARBALL" "https://download.flashcat.cloud/${TARBALL}" 2>/dev/null; then
        warn "国内下载站失败,改用 github..."
        curl -fSL -o "$TARBALL" "https://github.com/flashcatcloud/categraf/releases/download/${CATEGRAF_VERSION}/${TARBALL}" \
            || { error "Categraf 下载失败"; exit 1; }
    fi
    tar xf "$TARBALL"
    local SRC; SRC=$(find . -maxdepth 1 -type d -name "categraf-*" | head -n1)
    [ -n "$SRC" ] || { error "解压异常"; exit 1; }

    systemctl stop categraf >/dev/null 2>&1 || true
    mkdir -p "$CATEGRAF_DIR"; cp -rf "$SRC"/* "$CATEGRAF_DIR"/
    local CONF="$CATEGRAF_DIR/conf/config.toml"
    [ -f "$CONF" ] || { error "未找到 ${CONF}"; exit 1; }

    # 2) 配置写入地址 + 心跳地址 指向母鸡
    sed -i \
        -e "s|http://127.0.0.1:17000|http://${N9E_SERVER}:${N9E_PORT}|g" \
        -e "s|http://localhost:17000|http://${N9E_SERVER}:${N9E_PORT}|g" \
        -e "s|http://N9E:17000|http://${N9E_SERVER}:${N9E_PORT}|g" \
        "$CONF"
    sed -i "/\[heartbeat\]/,/^\[/ s/enable *= *false/enable = true/" "$CONF"
    info "已指向 http://${N9E_SERVER}:${N9E_PORT}"

    # 3) systemd
    cat > /etc/systemd/system/categraf.service <<EOF
[Unit]
Description=Categraf Agent (Nightingale)
After=network.target
[Service]
Type=simple
ExecStart=${CATEGRAF_DIR}/categraf
WorkingDirectory=${CATEGRAF_DIR}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable categraf >/dev/null 2>&1 || true
    systemctl restart categraf; sleep 2

    echo
    if systemctl is-active --quiet categraf; then
        info "============================================================"
        info " 节点接入完成 ✅  本机已设为开机自启"
        info "   日志: journalctl -u categraf -f"
        info "   稍等 10~30 秒,到夜莺『基础设施 → 机器列表』即可看到本机。"
        info "============================================================"
    else
        error "Categraf 启动失败: journalctl -u categraf -n 50"; exit 1
    fi
}

############################################################
# 卸载
############################################################
do_uninstall() {
    local target="${1:-auto}"
    local kill_master=0 kill_node=0
    local has_master=0 has_node=0
    systemctl list-unit-files 2>/dev/null | grep -q '^n9e\.service'      && has_master=1
    systemctl list-unit-files 2>/dev/null | grep -q '^categraf\.service' && has_node=1

    case "$target" in
        master) kill_master=1 ;;
        node)   kill_node=1 ;;
        all)    kill_master=1; kill_node=1 ;;
        auto)
            kill_master=$has_master; kill_node=$has_node
            if [ "$kill_master" -eq 0 ] && [ "$kill_node" -eq 0 ]; then
                warn "未检测到已安装的夜莺/采集器组件,无需卸载"; exit 0
            fi ;;
        *) error "未知卸载目标 '$target',可选: master | node | all"; exit 1 ;;
    esac

    local purge="${PURGE_DATA:-0}"
    info "准备卸载:$( [ "$kill_master" -eq 1 ] && echo -n '母鸡(n9e+VictoriaMetrics) ' )$( [ "$kill_node" -eq 1 ] && echo -n '节点(categraf)' )"
    if [ "$purge" = "1" ]; then
        warn "PURGE_DATA=1:将连同数据目录一起删除(SQLite、时序数据不可恢复)"
    else
        info "默认保留数据目录;如需彻底清除请加 PURGE_DATA=1"
    fi
    # 交互式二次确认(有终端时)
    if [ -t 0 ]; then
        read -rp "确认卸载?输入 yes 继续: " ans
        [ "$ans" = "yes" ] || { info "已取消"; exit 0; }
    fi

    _remove_unit() {  # $1=服务名 $2...=要删的目录
        local svc="$1"; shift
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            systemctl disable --now "$svc" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${svc}.service"
            info "已停止并移除服务 ${svc}"
        fi
        if [ "$purge" = "1" ]; then
            for d in "$@"; do [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" && info "已删除目录 $d"; done
        fi
    }

    if [ "$kill_master" -eq 1 ]; then
        _remove_unit n9e "$N9E_DIR"
        _remove_unit victoria-metrics "$VM_DIR"
    fi
    if [ "$kill_node" -eq 1 ]; then
        _remove_unit categraf "$CATEGRAF_DIR"
    fi

    systemctl daemon-reload 2>/dev/null || true
    echo
    info "卸载完成。"
    if [ "$purge" != "1" ]; then
        local kept=""
        [ "$kill_master" -eq 1 ] && kept="$kept $N9E_DIR $VM_DIR"
        [ "$kill_node" -eq 1 ]   && kept="$kept $CATEGRAF_DIR"
        warn "数据目录已保留:${kept# }"
        warn "如需彻底删除: PURGE_DATA=1 sudo $0 uninstall ${target}"
    fi
}

# ---------- 分发 ----------
case "$ROLE" in
    master)    deploy_master ;;
    node)      deploy_node ;;
    uninstall) do_uninstall "${UNINST_TARGET:-auto}" ;;
    *)         error "未确定角色"; exit 1 ;;
esac