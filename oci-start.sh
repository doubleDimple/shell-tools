#!/bin/bash
#
# 作者: doubleDimple
# 描述: OCI-Start 应用的启动/停止/管理脚本，支持自定义端口和公网IP显示。
# 用法: ./oci-start.sh {start|stop|restart|status|update|uninstall} [-p <port>]
# 示例:
#   启动到默认端口 9856: ./oci-start.sh start
#   启动到自定义端口 30998: ./oci-start.sh start -p 30998
#   重启到新端口 8080: ./oci-start.sh restart -p 8080

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

DEFAULT_PORT=9856
CUSTOM_PORT=$DEFAULT_PORT # 初始值是默认值

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

SCRIPT_REAL_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

JAR_PATH="/root/oci-start/oci-start-release.jar"
LOG_FILE="/dev/null"
JAR_DIR="$(dirname "$JAR_PATH")"
SCRIPT_PATH=$(readlink -f "$0")
SYMLINK_PATH="/usr/local/bin/oci-start"

JVM_OPTS="-XX:+UseG1GC"


is_china_network() {
    log_info "正在检测网络环境..."
    
    if curl -s --connect-timeout 5 --max-time 5 https://google.com > /dev/null 2>&1; then
        log_info "检测到可访问Google，判断为国外网络环境"
        return 1
    else
        log_info "检测到无法访问Google，判断为国内网络环境"
        return 0
    fi
}

check_java() {
    if ! command -v java &> /dev/null; then
        log_warn "未检测到Java，准备安装JDK..."
        install_java
    else
        java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
        log_info "检测到Java版本: $java_version"
    fi
}

install_java() {
    log_info "开始安装Java..."
    if command -v apt &> /dev/null; then
        log_info "使用apt安装JDK..."
        apt update -y
        DEBIAN_FRONTEND=noninteractive apt install -y default-jdk
    elif command -v yum &> /dev/null; then
        log_info "使用yum安装JDK..."
        yum update -y
        yum install -y java-11-openjdk
    elif command -v dnf &> /dev/null; then
        log_info "使用dnf安装JDK..."
        dnf update -y
        dnf install -y java-11-openjdk
    else
        log_error "不支持的操作系统，请手动安装Java"
        exit 1
    fi

    if ! command -v java &> /dev/null; then
        log_error "Java安装失败"
        exit 1
    else
        java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
        log_success "Java安装成功，版本: $java_version"
    fi
}

check_websockify() {
    if ! command -v websockify &> /dev/null; then
        log_warn "未检测到Websockify，准备安装..."
        install_websockify
    else
        websockify_version=$(websockify --help 2>&1 | head -1 | grep -o 'v[0-9.]*' || echo "未知版本")
    fi
}

install_websockify() {
    log_info "开始安装Websockify..."
    
    if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
        log_info "Python未安装，正在安装Python..."
        if command -v apt &> /dev/null; then
            apt update -y
            DEBIAN_FRONTEND=noninteractive apt install -y python3 python3-pip
        elif command -v yum &> /dev/null; then
            yum update -y
            yum install -y python3 python3-pip
        elif command -v dnf &> /dev/null; then
            dnf update -y
            dnf install -y python3 python3-pip
        else
            log_error "不支持的操作系统，请手动安装Python"
            exit 1
        fi
    fi
    
    PYTHON_CMD=""
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
    else
        log_error "Python安装后仍无法找到，请检查安装"
        exit 1
    fi
    
    PIP_CMD=""
    if command -v pip3 &> /dev/null; then
        PIP_CMD="pip3"
    elif command -v pip &> /dev/null; then
        PIP_CMD="pip"
    elif $PYTHON_CMD -m pip --version &> /dev/null; then
        PIP_CMD="$PYTHON_CMD -m pip"
    else
        log_error "pip未找到，尝试安装pip..."
        if command -v apt &> /dev/null; then
            apt install -y python3-pip
            PIP_CMD="pip3"
        elif command -v yum &> /dev/null; then
            yum install -y python3-pip
            PIP_CMD="pip3"
        elif command -v dnf &> /dev/null; then
            dnf install -y python3-pip
            PIP_CMD="pip3"
        else
            log_error "无法安装pip，请手动安装"
            exit 1
        fi
    fi
    
    local installed_via_package=false
    if command -v apt &> /dev/null; then
        log_info "尝试通过apt安装websockify..."
        if apt install -y websockify 2>/dev/null; then
            installed_via_package=true
            log_success "通过apt成功安装websockify"
        else
            log_warn "apt安装websockify失败，将使用pip安装"
        fi
    elif command -v yum &> /dev/null; then
        log_info "尝试通过yum安装websockify..."
        if yum install -y python3-websockify 2>/dev/null || yum install -y websockify 2>/dev/null; then
            installed_via_package=true
            log_success "通过yum成功安装websockify"
        else
            log_warn "yum安装websockify失败，将使用pip安装"
        fi
    elif command -v dnf &> /dev/null; then
        log_info "尝试通过dnf安装websockify..."
        if dnf install -y python3-websockify 2>/dev/null; then
            installed_via_package=true
            log_success "通过dnf成功安装websockify"
        else
            log_warn "dnf安装websockify失败，将使用pip安装"
        fi
    fi
    
    if [ "$installed_via_package" = false ]; then
        log_info "使用pip安装websockify..."
        if $PIP_CMD install websockify; then
            log_success "通过pip成功安装websockify"
        else
            log_error "pip安装websockify失败，尝试升级pip后重试..."
            $PIP_CMD install --upgrade pip
            if $PIP_CMD install websockify; then
                log_success "升级pip后成功安装websockify"
            else
                log_error "websockify安装失败，请手动安装"
                exit 1
            fi
        fi
    fi
    
    if ! command -v websockify &> /dev/null; then
        log_error "websockify安装失败，命令不可用"
        exit 1
    else
        websockify_version=$(websockify --help 2>&1 | head -1 | grep -o 'v[0-9.]*' || echo "未知版本")
        log_success "Websockify安装成功，版本: $websockify_version"
    fi
}

create_symlink() {
    if [ ! -L "$SYMLINK_PATH" ] || [ "$(readlink "$SYMLINK_PATH")" != "$SCRIPT_PATH" ]; then
        log_info "创建软链接: $SYMLINK_PATH -> $SCRIPT_PATH"
        mkdir -p "$(dirname "$SYMLINK_PATH")" 2>/dev/null
        if ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH" 2>/dev/null; then
            log_success "软链接创建成功，现在可以使用 'oci-start' 命令"
        else
            log_warn "没有权限创建软链接，尝试使用sudo"
            if command -v sudo &>/dev/null; then
                sudo ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH"
                log_success "软链接创建成功，现在可以使用 'oci-start' 命令"
            else
                log_error "创建软链接失败，请确保有足够权限或手动创建"
            fi
        fi
    fi
}

check_and_download_jar() {
    if [ ! -f "$JAR_PATH" ]; then
        log_info "未找到JAR包，准备下载最新版本..."
        mkdir -p "$(dirname "$JAR_PATH")"
        update_latest
        if [ ! -f "$JAR_PATH" ]; then
            log_error "下载JAR包失败"
            exit 1
        fi
    fi
}

get_public_ip() {
    log_info "正在尝试获取公网IP..."
    
    local ip=$(curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org || \
               curl -s --connect-timeout 5 --max-time 10 http://ifconfig.me/ip || \
               curl -s --connect-timeout 5 --max-time 10 http://ip.sb)
    
    if echo "$ip" | grep -E -q '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        log_success "成功获取公网IP: $ip"
        echo "$ip"
    else
        log_warn "无法获取公网IP，将使用内网IP"
        local internal_ip=$(hostname -I | awk '{print $1}')
        if [ -z "$internal_ip" ]; then
            internal_ip=$(ip route get 1 | awk '{print $(NF-2);exit}')
        fi
        echo "$internal_ip"
    fi
}

start() {
    cd "$SCRIPT_REAL_DIR" || {
        log_error "无法切换到脚本目录: $SCRIPT_REAL_DIR"
        exit 1
    }
    
    check_java
    
    check_websockify
    
    check_and_download_jar
    
    create_symlink
    
    log_success "环境准备完成，现在可以使用 'oci-start' 命令"

    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_warn "应用已经在运行中"
        exit 0
    fi

    log_info "正在启动应用 (端口: $CUSTOM_PORT)..."

    # 使用当前的 $CUSTOM_PORT 启动应用
    nohup java $JVM_OPTS -Dserver.port="$CUSTOM_PORT" -jar "$JAR_PATH" > "$LOG_FILE" 2>&1 &

    sleep 3
    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_success "应用启动成功"

        IP=$(get_public_ip)

        echo -e "${BLUE}欢迎使用oci-start${NC}"
        echo -e "${CYAN}访问地址为: ${NC}http://${IP}:${CUSTOM_PORT}"

    else
        log_error "应用启动失败"
        exit 1
    fi
}

stop() {
    cd "$SCRIPT_REAL_DIR" || {
        log_error "无法切换到脚本目录: $SCRIPT_REAL_DIR"
        exit 1
    }
    
    create_symlink
    
    PIDS=$(pgrep -f "$JAR_PATH")
    if [ -z "$PIDS" ]; then
        log_warn "应用未在运行"
        return 0
    fi

    log_info "正在停止应用... (PIDS: $PIDS)"
    
    kill $PIDS 2>/dev/null
    
    local count=0
    while [ $count -lt 10 ]; do
        if ! pgrep -f "$JAR_PATH" > /dev/null; then
            log_success "应用已停止"
            return 0
        fi
        sleep 1
        count=$((count + 1))
        log_info "等待进程停止... ($count/10)"
    done
    
    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_warn "强制停止应用..."
        kill -9 $(pgrep -f "$JAR_PATH") 2>/dev/null
        sleep 2
        
        if pgrep -f "$JAR_PATH" > /dev/null; then
            log_error "无法停止应用"
            return 1
        else
            log_success "应用已强制停止"
            return 0
        fi
    fi
    
    log_success "应用已停止"
    return 0
}

restart() {
    cd "$SCRIPT_REAL_DIR" || {
        log_error "无法切换到脚本目录: $SCRIPT_REAL_DIR"
        exit 1
    }

    # --- 新增逻辑：自动继承旧端口 ---
    if pgrep -f "$JAR_PATH" > /dev/null; then
        # 1. 获取当前运行的进程PID (取第一个)
        local pid=$(pgrep -f "$JAR_PATH" | head -n 1)
        
        # 2. 从进程启动命令中提取 server.port 的值
        # ps -p <pid> -o args= 会输出完整的启动命令
        local running_port=$(ps -p "$pid" -o args= | grep -o 'server\.port=[0-9]*' | cut -d '=' -f 2)

        # 3. 判断：如果获取到了旧端口，且用户本次没有通过 -p 指定新端口(即 CUSTOM_PORT 仍为默认值)
        # 那么就强制将端口变量修改为旧端口
        if [ -n "$running_port" ]; then
            if [ "$CUSTOM_PORT" -eq "$DEFAULT_PORT" ]; then
                log_info "检测到上次运行端口为: $running_port，将继承该端口进行重启..."
                CUSTOM_PORT=$running_port
            else
                log_info "检测到上次运行端口为: $running_port，但用户指定了新端口: $CUSTOM_PORT，将使用新端口。"
            fi
        fi
    fi
    # --- 新增逻辑结束 ---
    
    check_java
    check_websockify
    create_symlink
    
    stop
    start
}

status() {
    cd "$SCRIPT_REAL_DIR" || {
        log_error "无法切换到脚本目录: $SCRIPT_REAL_DIR"
        exit 1
    }
    
    check_java
    check_websockify
    create_symlink
    
    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_success "应用正在运行"
    else
        log_error "应用未运行"
    fi
}

update_latest() {
    cd "$SCRIPT_REAL_DIR" || {
        log_error "无法切换到脚本目录: $SCRIPT_REAL_DIR"
        exit 1
    }
    
    check_java
    check_websockify

    # === 新增逻辑开始：在停止服务前，先记录当前端口 ===
    local PREVIOUS_PORT=""
    if pgrep -f "$JAR_PATH" > /dev/null; then
        local pid=$(pgrep -f "$JAR_PATH" | head -n 1)
        PREVIOUS_PORT=$(ps -p "$pid" -o args= | grep -o 'server\.port=[0-9]*' | cut -d '=' -f 2)
        if [ -n "$PREVIOUS_PORT" ]; then
            log_info "检测到当前运行端口为: $PREVIOUS_PORT，更新后将维持该端口。"
        fi
    fi
    # === 新增逻辑结束 ===
    
    log_info "开始检查更新..."
    mkdir -p "$JAR_DIR"
    
    if ! command -v curl &> /dev/null; then
        log_info "安装curl..."
        if command -v apt &> /dev/null; then
            apt update -y
            apt install -y curl
        elif command -v yum &> /dev/null; then
            yum install -y curl
        elif command -v dnf &> /dev/null; then
            dnf install -y curl
        else
            log_error "不支持的操作系统，请手动安装curl"
            exit 1
        fi
    fi
    
    local api_url="https://api.github.com/repos/doubleDimple/oci-start/releases/latest"
    
    log_info "获取最新版本信息..."
    local download_url=$(curl -s --connect-timeout 10 --max-time 30 "$api_url" | grep "browser_download_url.*jar" | cut -d '"' -f 4)

    if [ -z "$download_url" ]; then
        log_error "无法获取最新版本信息，请检查网络连接"
        return 1
    fi
    
    if is_china_network; then
        download_url="https://speed.objboy.com/$download_url"
        log_info "使用国内加速下载地址"
    fi

    local latest_version=$(curl -s --connect-timeout 10 --max-time 30 "$api_url" | grep '"tag_name":' | cut -d '"' -f 4)
    log_info "找到最新版本: ${latest_version}"
    log_info "开始下载..."

    local temp_file="${JAR_PATH}.temp"
    local backup_file="${JAR_PATH}.${latest_version}.bak"

    log_info "下载文件到: $temp_file"
    if curl -L --connect-timeout 30 --max-time 300 -o "$temp_file" "$download_url"; then
        if [ ! -f "$temp_file" ] || [ ! -s "$temp_file" ]; then
            log_error "下载的文件无效"
            rm -f "$temp_file"
            return 1
        fi
        
        if command -v file &> /dev/null; then
            if ! file "$temp_file" | grep -q "Java archive\|Zip archive"; then
                log_error "下载的文件不是有效的JAR文件"
                rm -f "$temp_file"
                return 1
            fi
        fi
        
        log_success "文件下载完成"
        
        log_info "停止当前应用..."
        if ! stop; then
            log_error "停止应用失败"
            rm -f "$temp_file"
            return 1
        fi
        
        if [ -f "$JAR_PATH" ]; then
            if cp "$JAR_PATH" "$backup_file"; then
                log_info "原JAR包已备份为: $backup_file"
            else
                log_error "无法创建备份文件"
                rm -f "$temp_file"
                return 1
            fi
        fi

        if mv "$temp_file" "$JAR_PATH"; then
            chmod +x "$JAR_PATH"
            log_success "JAR包更新完成，版本：${latest_version}"
            
            log_info "启动新版本..."
            
            # === 新增逻辑开始：恢复之前的端口 ===
            if [ -n "$PREVIOUS_PORT" ]; then
                CUSTOM_PORT=$PREVIOUS_PORT
            fi
            # === 新增逻辑结束 ===
            
            if start; then
                sleep 5
                if pgrep -f "$JAR_PATH" > /dev/null; then
                    log_success "新版本启动成功，清理备份文件..."
                    rm -f "$backup_file"
                    return 0
                else
                    log_error "新版本启动失败，恢复备份版本"
                    if [ -f "$backup_file" ]; then
                        mv "$backup_file" "$JAR_PATH"
                        log_info "已恢复备份版本"
                        start
                    fi
                    return 1
                fi
            else
                log_error "启动失败"
                return 1
            fi
        else
            log_error "文件替换失败"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "下载失败，请检查网络连接"
        rm -f "$temp_file"
        return 1
    fi
}


uninstall() {
    cd "$SCRIPT_REAL_DIR" || {
        log_error "无法切换到脚本目录: $SCRIPT_REAL_DIR"
        exit 1
    }
    
    echo -e "${YELLOW}确认卸载说明:${NC}"
    echo -e "1. 将停止并删除所有应用相关文件"
    echo -e "2. 此操作不可逆，请确认"
    echo -ne "${YELLOW}确认继续卸载吗? [y/N]: ${NC}"
    read -r response

    case "$response" in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            log_info "取消卸载操作"
            exit 0
            ;;
    esac

    log_info "开始卸载应用..."

    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_info "正在停止应用进程..."
        stop
        sleep 2
    fi

    [ -f "$JAR_PATH" ] && rm -f "$JAR_PATH"
    
    find "$JAR_DIR" -name "*.bak" -o -name "*.backup" -o -name "*.temp" -o -name "*.log" -delete 2>/dev/null

    if [ -L "$SYMLINK_PATH" ]; then
        log_info "正在删除软链接..."
        rm -f "$SYMLINK_PATH"
    fi

    if [ ! -f "$JAR_PATH" ] && [ ! -L "$SYMLINK_PATH" ]; then
        log_success "应用卸载完成"
        echo -e "${GREEN}如需重新安装应用，请使用 'start' 命令${NC}"
        echo -e "${YELLOW}注意: Java和Websockify未被卸载，如需卸载请手动操作${NC}"
    else
        log_error "卸载未完全成功，请检查日志"
    fi
}

parse_args() {
    # 只处理 $1 开始的参数列表
    local args=("$@") # 将所有参数复制到局部数组
    
    for (( i=0; i<${#args[@]}; i++ )); do
        arg="${args[i]}"
        next_arg="${args[i+1]}"
        
        if [[ "$arg" == "-p" || "$arg" == "--port" ]]; then
            # 检查 $2 是否存在
            if [ -z "$next_arg" ]; then
                log_error "缺少端口号参数，请使用 -p <端口号> 指定。"
                exit 1
            fi
            
            # 检查 $2 是否为数字 (POSIX兼容)
            if ! [ "$next_arg" -eq "$next_arg" ] 2>/dev/null; then
                log_error "端口参数无效: $next_arg。端口号必须是数字。"
                exit 1
            fi
            
            # 检查范围
            if [ "$next_arg" -ge 1 ] && [ "$next_arg" -le 65535 ]; then
                CUSTOM_PORT="$next_arg"
                return 0 # 找到端口并设置，直接退出函数
            else
                log_error "端口参数无效: $next_arg。请提供一个1到65535之间的数字。"
                exit 1
            fi
        fi
    done
    return 0
}

COMMAND=$1

# 步骤 1: 解析命令行参数。如果提供了 -p，会覆盖默认端口。
if [ "$COMMAND" = "start" ] || [ "$COMMAND" = "restart" ]; then
    # 只解析命令之后的参数 (shift 一次)
    parse_args "${@:2}"
fi

case "$COMMAND" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    update)
        update_latest
        ;;
    uninstall)
        uninstall
        ;;
    *)
        echo -e "${YELLOW}Usage: $0 {start|stop|restart|status|update|uninstall} [-p <port>]${NC}"
        echo -e "${YELLOW}Example: $0 start -p 30998${NC}"
        exit 1
        ;;
esac
