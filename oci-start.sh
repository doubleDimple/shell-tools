#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志函数
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

# 应用配置
JAR_PATH="/root/oci-start/oci-start-release.jar"
LOG_FILE="/dev/null"
JAR_DIR="$(dirname "$JAR_PATH")"
SCRIPT_PATH=$(realpath "$0")
SYMLINK_PATH="/usr/local/bin/oci-start"

# JVM参数
JVM_OPTS="-XX:+UseG1GC"

# 检查Java是否已安装
check_java() {
    if ! command -v java &> /dev/null; then
        log_warn "未检测到Java，准备安装JDK..."
        install_java
    else
        java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
        log_info "检测到Java版本: $java_version"
    fi
}

# 安装Java
install_java() {
    log_info "开始安装Java..."
    if command -v apt &> /dev/null; then
        # Debian/Ubuntu
        log_info "使用apt安装JDK..."
        apt update -y
        DEBIAN_FRONTEND=noninteractive apt install -y default-jdk
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        log_info "使用yum安装JDK..."
        yum update -y
        yum install -y java-11-openjdk
    elif command -v dnf &> /dev/null; then
        # Fedora
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

# 创建软链接
create_symlink() {
    if [ ! -L "$SYMLINK_PATH" ] || [ "$(readlink "$SYMLINK_PATH")" != "$SCRIPT_PATH" ]; then
        log_info "创建软链接: $SYMLINK_PATH -> $SCRIPT_PATH"
        # 确保目标目录存在
        mkdir -p "$(dirname "$SYMLINK_PATH")" 2>/dev/null
        # 尝试创建软链接，如果没有权限则提示使用sudo
        if ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH" 2>/dev/null; then
            log_success "软链接创建成功，现在可以使用 'oci-start' 命令"
        else
            log_warn "没有权限创建软链接，尝试使用sudo"
            if command -v sudo &>/dev/null; then
                sudo ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH"
                log_success "软链接创建成功，现在可以使用 'oci-quick' 命令"
            else
                log_error "创建软链接失败，请确保有足够权限或手动创建"
            fi
        fi
    fi
}

# 检查并下载jar包
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

start() {
    # 检查Java安装，自动安装JDK
    check_java
    
    # 检查并下载jar包
    check_and_download_jar
    
    # 创建软链接
    create_symlink
    
    # 输出成功提示
    log_success "环境准备完成，现在可以使用 'oci-start' 命令"

    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_warn "应用已经在运行中"
        exit 0
    fi

    log_info "正在启动应用..."

    # 启动应用
    nohup java $JVM_OPTS -jar $JAR_PATH > $LOG_FILE 2>&1 &

    # 等待几秒检查是否成功启动
    sleep 3
    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_success "应用启动成功"

        # 获取系统IP地址
        IP=$(hostname -I | awk '{print $1}')
        if [ -z "$IP" ]; then
            IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
        fi

        # 输出访问地址
        echo -e "${BLUE}欢迎使用oci-start${NC}"
        echo -e "${CYAN}访问地址为: ${NC}http://${IP}:9856"

    else
        log_error "应用启动失败"
        exit 1
    fi
}

stop() {
    # 创建软链接，确保停止后仍然可以使用oci-start命令
    create_symlink
    
    PIDS=$(pgrep -f "$JAR_PATH")
    if [ -z "$PIDS" ]; then
        log_warn "应用未在运行"
        return
    fi

    log_info "正在停止应用..."
    kill $PIDS
    sleep 2
    if pgrep -f "$JAR_PATH" > /dev/null; then
        kill -9 $(pgrep -f "$JAR_PATH")
    fi
    log_success "应用已停止"
}

restart() {
    # 重启时也检查环境
    check_java
    create_symlink
    stop
    start
}

status() {
    # 在所有命令中都增加环境检查
    check_java
    create_symlink
    
    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_success "应用正在运行"
    else
        log_error "应用未运行"
    fi
}

update_latest() {
    # 检查Java安装
    check_java
    
    log_info "开始检查更新..."
    mkdir -p "$JAR_DIR"
    local api_url="https://api.github.com/repos/doubleDimple/oci-start/releases/latest"
    
    # 检查是否安装了curl
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
    
    local download_url=$(curl -s "$api_url" | grep "browser_download_url.*jar" | cut -d '"' -f 4)

    if [ -z "$download_url" ]; then
        log_error "无法获取最新版本信息"
        return 1
    fi

    local latest_version=$(curl -s "$api_url" | grep '"tag_name":' | cut -d '"' -f 4)
    log_info "找到最新版本: ${latest_version}"
    log_info "开始下载..."

    local temp_file="${JAR_PATH}.temp"
    local backup_file="${JAR_PATH}.${latest_version}.bak"

    if curl -L -o "$temp_file" "$download_url"; then
        stop
        if [ -f "$JAR_PATH" ]; then
            mv "$JAR_PATH" "$backup_file"
            log_info "原JAR包已备份为: $backup_file"
        fi

        mv "$temp_file" "$JAR_PATH"
        chmod +x "$JAR_PATH"

        log_success "更新完成，版本：${latest_version}"
        start

        sleep 5
        if pgrep -f "$JAR_PATH" > /dev/null; then
            log_success "新版本启动成功，清理备份文件..."
            rm -f "$backup_file"
        else
            log_error "新版本启动失败，保留备份文件"
            log_info "备份文件位置: $backup_file"
            return 1
        fi
    else
        log_error "下载失败"
        rm -f "$temp_file"
        return 1
    fi
}

uninstall() {
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

    # 停止应用
    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_info "正在停止应用进程..."
        stop
        sleep 2
    fi

    # 删除应用文件
    [ -f "$JAR_PATH" ] && rm -f "$JAR_PATH"

    # 清理其他文件
    find "$JAR_DIR" -name "*.bak" -o -name "*.backup" -o -name "*.temp" -o -name "*.log" -delete 2>/dev/null

    # 删除软链接
    if [ -L "$SYMLINK_PATH" ]; then
        log_info "正在删除软链接..."
        rm -f "$SYMLINK_PATH"
    fi

    # 检查是否清理完成
    if [ ! -f "$JAR_PATH" ] && [ ! -L "$SYMLINK_PATH" ]; then
        log_success "应用卸载完成"
        echo -e "${GREEN}如需重新安装应用，请使用 'start' 命令${NC}"
    else
        log_error "卸载未完全成功，请检查日志"
    fi
}

# 移除独立的setup函数，在其他命令中集成这些功能

# 主命令处理
case "$1" in
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
        echo -e "${YELLOW}Usage: $0 {start|stop|restart|status|update|uninstall}${NC}"
        exit 1
        ;;
esac
