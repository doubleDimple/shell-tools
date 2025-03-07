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
DB_CONFIG_FILE="${JAR_DIR}/db_config.properties"
APP_CONFIG_FILE="./data/application.yml"

# JVM参数
JVM_OPTS="-XX:+UseG1GC"

# 生成随机密码
generate_db_password() {
    # 生成一个16位的随机密码，包含大小写字母、数字和特殊字符
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+"
    local length=16
    local password=""

    for (( i=0; i<length; i++ )); do
        local rand=$((RANDOM % ${#chars}))
        password+=${chars:$rand:1}
    done

    echo "$password"
}

# 更新配置文件中的数据库密码
update_db_password() {
    local new_password=$(generate_db_password)
    log_info "正在生成数据库密码..."

    # 保存密码到配置文件以便查询
    mkdir -p "$(dirname "$DB_CONFIG_FILE")"
    echo "DB_PASSWORD=${new_password}" > "$DB_CONFIG_FILE"
    chmod 600 "$DB_CONFIG_FILE"

    # 更新应用配置文件
    if [ -f "$APP_CONFIG_FILE" ]; then
        log_info "更新应用配置文件中的密码..."
        # 备份原配置文件
        cp "$APP_CONFIG_FILE" "${APP_CONFIG_FILE}.bak"

        # 使用sed直接替换环境变量引用为实际密码值
        sed -i "s/password: .*$/password: $new_password/" "$APP_CONFIG_FILE"

        if [ $? -ne 0 ]; then
            log_error "更新配置文件失败，请检查配置文件权限"
            return 1
        fi
        log_success "配置文件已更新"
    else
        log_warn "应用配置文件不存在: $APP_CONFIG_FILE"
        log_info "将在应用首次启动时自动创建"
    fi

    log_success "数据库密码已生成并更新"
    return 0
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

    # 更新数据库密码
    update_db_password

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

        # 输出访问地址和数据库信息
        echo -e "${BLUE}欢迎使用oci-start${NC}"
        echo -e "${CYAN}访问地址为: ${NC}http://${IP}:9856"

        # 显示数据库配置信息
        if [ -f "$DB_CONFIG_FILE" ]; then
            local db_password=$(grep "DB_PASSWORD" "$DB_CONFIG_FILE" | cut -d'=' -f2)
            echo -e "\n${BLUE}数据库配置信息：${NC}"
            echo -e "${CYAN}类型:${NC} H2内嵌数据库"
            echo -e "${CYAN}当前密码:${NC} $db_password"
        fi

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

        # 获取系统IP地址
        IP=$(hostname -I | awk '{print $1}')
        if [ -z "$IP" ]; then
            IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
        fi

        echo -e "\n${BLUE}应用信息：${NC}"
        echo -e "${CYAN}访问地址:${NC} http://${IP}:9856"
        echo -e "${CYAN}数据库:${NC} H2"

        if [ -f "$DB_CONFIG_FILE" ]; then
            # 从配置文件读取密码
            local db_password=$(grep "DB_PASSWORD" "$DB_CONFIG_FILE" | cut -d'=' -f2)
            echo -e "${CYAN}密码配置文件:${NC} $DB_CONFIG_FILE"
            echo -e "${CYAN}当前密码:${NC} $db_password"
        else
            echo -e "${CYAN}密码配置:${NC} 未保存配置文件"
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
    [ -f "$DB_CONFIG_FILE" ] && rm -f "$DB_CONFIG_FILE"

    # 清理其他文件
    find "$JAR_DIR" -name "*.bak" -o -name "*.backup" -o -name "*.temp" -o -name "*.log" -delete 2>/dev/null

    # 检查是否清理完成
    if [ ! -f "$JAR_PATH" ]; then
        log_success "应用卸载完成"
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