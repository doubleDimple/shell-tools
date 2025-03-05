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

# JVM参数
JVM_OPTS="-XX:+UseG1GC"

# Redis默认配置
REDIS_PORT="56689"
REDIS_CONFIG="/etc/redis/redis.conf"
REDIS_INFO_FILE="/etc/redis/redis_info"

# Redis配置检查函数
check_redis_config() {
    local redis_port=""
    local redis_password=""
    local password_enabled="false"

    # 检查Redis是否已安装
    if ! command -v redis-cli >/dev/null 2>&1; then
        log_error "Redis未安装"
        return 1
    fi

    # 获取Redis端口
    local running_port=$(ps aux | grep redis-server | grep -v grep | awk '{print $12}' | cut -d':' -f2)
    if [ -z "$running_port" ]; then
        log_error "Redis未运行"
        return 1
    fi

    redis_port=$running_port
    log_info "检测到Redis运行在端口 ${redis_port}"

    # 首先检查配置文件中是否设置了密码
    if [ -f "/etc/redis/redis.conf" ]; then
        local conf_password=$(grep "^requirepass" /etc/redis/redis.conf 2>/dev/null | awk '{print $2}')
        if [ ! -z "$conf_password" ]; then
            redis_password=$conf_password
            password_enabled="true"
            log_success "检测到Redis已配置密码认证"
        else
            log_info "Redis未配置密码认证"
        fi
    fi

    # 设置环境变量
    export SPRING_REDIS_HOST=localhost
    export SPRING_REDIS_PORT=$redis_port
    export SPRING_REDIS_PASSWORD_ENABLED=$password_enabled
    if [ "$password_enabled" = "true" ]; then
        export SPRING_REDIS_PASSWORD=$redis_password
    fi

    # 保存配置信息
    mkdir -p "$(dirname "$REDIS_INFO_FILE")"
    echo "REDIS_PORT=${redis_port}" > "$REDIS_INFO_FILE"
    echo "REDIS_PASSWORD_ENABLED=${password_enabled}" >> "$REDIS_INFO_FILE"
    if [ "$password_enabled" = "true" ]; then
        echo "REDIS_PASSWORD=${redis_password}" >> "$REDIS_INFO_FILE"
    fi
    chmod 600 "$REDIS_INFO_FILE"

    # 输出Redis配置信息
    echo -e "\n${BLUE}Redis配置信息：${NC}"
    echo -e "${CYAN}地址:${NC} localhost"
    echo -e "${CYAN}端口:${NC} ${redis_port}"
    echo -e "${CYAN}密码认证:${NC} $([ "$password_enabled" = "true" ] && echo "已启用" || echo "未启用")"
    if [ "$password_enabled" = "true" ]; then
        echo -e "${CYAN}密码:${NC} ${redis_password}"
    fi
    echo -e ""

    return 0
}

# 安装Redis
install_redis() {
    log_info "开始安装Redis..."

    # 安装Redis
    if [ -f /etc/redhat-release ]; then
        # RedHat/CentOS
        yum install -y epel-release redis >/dev/null 2>&1
    elif [ -f /etc/alpine-release ]; then
        # Alpine Linux
        apk update >/dev/null 2>&1
        apk add redis >/dev/null 2>&1
    else
        # Debian/Ubuntu
        apt-get update >/dev/null 2>&1
        apt-get install -y redis-server >/dev/null 2>&1
    fi

    # 创建必要的目录
    mkdir -p /var/lib/redis /var/log/redis /var/run/redis

    # Alpine 使用不同的用户组
    if [ -f /etc/alpine-release ]; then
        addgroup -S redis 2>/dev/null || true
        adduser -S -G redis redis 2>/dev/null || true
    fi

    chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis
    chmod 750 /var/lib/redis /var/log/redis /var/run/redis

    # 创建Redis配置文件
    cat > $REDIS_CONFIG << EOF
port ${REDIS_PORT}
bind 127.0.0.1
dir /var/lib/redis
daemonize yes
pidfile /var/run/redis/redis-server.pid
logfile /var/log/redis/redis-server.log
EOF

    # 设置配置文件权限
    chown redis:redis $REDIS_CONFIG
    chmod 640 $REDIS_CONFIG

    # 在 Alpine 中使用 OpenRC 而不是 systemd
    if [ -f /etc/alpine-release ]; then
        rc-update add redis default
        rc-service redis restart
    else
        systemctl daemon-reload
        systemctl restart redis-server.service
    fi
    sleep 2

    # 验证Redis运行状态
    if redis-cli -p ${REDIS_PORT} ping >/dev/null 2>&1; then
        log_success "Redis安装成功并正在运行"
        # 保存Redis配置信息
        echo "REDIS_PORT=${REDIS_PORT}" > "$REDIS_INFO_FILE"
        echo "REDIS_PASSWORD_ENABLED=false" >> "$REDIS_INFO_FILE"
        chmod 600 "$REDIS_INFO_FILE"

        # 导出环境变量
        export SPRING_REDIS_HOST=localhost
        export SPRING_REDIS_PORT=$REDIS_PORT
        export SPRING_REDIS_PASSWORD_ENABLED=false

        echo -e "\n${BLUE}Redis配置信息：${NC}"
        echo -e "${CYAN}端口:${NC} ${REDIS_PORT}"
        echo -e "${CYAN}密码认证:${NC} 未启用"
        echo -e ""
    else
        log_error "Redis安装失败"
        if [ -f /etc/alpine-release ]; then
            rc-service redis status
        else
            systemctl status redis-server.service
        fi
        exit 1
    fi
}

# 检查和配置Redis
setup_redis() {
    if check_redis_config; then
        log_success "使用现有Redis配置"
    else
        log_info "准备安装新的Redis实例..."
        install_redis
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
    # 检查并下载jar包
    check_and_download_jar

    # 检查和配置Redis
    setup_redis

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

        # 输出访问地址和Redis信息
        echo -e "${BLUE}欢迎使用oci-start${NC}"
        echo -e "${CYAN}访问地址为: ${NC}http://${IP}:9856"

    else
        log_error "应用启动失败"
        exit 1
    fi
}

stop() {
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
    stop
    start
}

status() {
    if pgrep -f "$JAR_PATH" > /dev/null; then
        log_success "应用正在运行"
        if [ -f "$REDIS_INFO_FILE" ]; then
            # 显示Redis配置信息
            local redis_port=$(grep "REDIS_PORT" "$REDIS_INFO_FILE" | cut -d'=' -f2)
            local redis_enabled=$(grep "REDIS_PASSWORD_ENABLED" "$REDIS_INFO_FILE" | cut -d'=' -f2)

            echo -e "\n${BLUE}Redis配置：${NC}"
            echo -e "${CYAN}地址:${NC} localhost"
            echo -e "${CYAN}端口:${NC} ${redis_port}"

            if [ "$redis_enabled" = "true" ]; then
                local redis_password=$(grep "REDIS_PASSWORD" "$REDIS_INFO_FILE" | cut -d'=' -f2)
                echo -e "${CYAN}密码认证:${NC} 已启用"
                echo -e "${CYAN}密码:${NC} ${redis_password}"
            else
                echo -e "${CYAN}密码认证:${NC} 未启用"
            fi
        else
            log_warn "未找到Redis配置信息"
        fi
    else
        log_error "应用未运行"
    fi
}

update_latest() {
    log_info "开始检查更新..."
    mkdir -p "$JAR_DIR"
    local api_url="https://api.github.com/repos/doubleDimple/oci-start/releases/latest"
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
    # 保存现有Redis配置信息（如果需要的话）
    if [ -f "$REDIS_INFO_FILE" ]; then
        cp "$REDIS_INFO_FILE" "${REDIS_INFO_FILE}.backup"
    fi

    echo -e "${YELLOW}确认卸载说明:${NC}"
    echo -e "1. 将停止并删除所有应用相关文件"
    echo -e "2. Redis服务和配置将保留"
    echo -e "3. 此操作不可逆，请确认"
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

    # 检查是否清理完成
    if [ ! -f "$JAR_PATH" ]; then
        log_success "应用卸载完成"
        if [ -f "${REDIS_INFO_FILE}.backup" ]; then
            mv "${REDIS_INFO_FILE}.backup" "$REDIS_INFO_FILE"
            echo -e "${GREEN}Redis配置已保存，下次安装时将自动使用相同配置${NC}"
        fi
        echo -e "${GREEN}如需重新安装应用，请使用 'start' 命令${NC}"
    else
        log_error "卸载未完全成功，请检查日志"
    fi
}

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
