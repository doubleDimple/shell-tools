#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color


# 使用示例
# 1. 默认安装（将安装到 /root/oci-start-docker 目录）：
#    ./docker.sh install
#
# 2. 指定目录安装（三种方式）：
#    a. 一次性指定：
#       OCI_APP_DIR=/root/oci-start-docker ./docker.sh install
#
#    b. 临时指定（仅对当前终端有效）：
#       export OCI_APP_DIR=/root/oci-start-docker
#       ./docker.sh install
#
#    c. 永久指定（对当前用户永久有效）：
#       echo 'export OCI_APP_DIR=/root/oci-start-docker' >> ~/.bashrc
#       source ~/.bashrc
#       ./docker.sh install
#
# 3. 卸载应用：
#    ./docker.sh uninstall


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

# 配置变量
#APP_DIR="/root/oci-start-docker"
APP_DIR="${OCI_APP_DIR:-/root/oci-start-docker}"  #替换原来的 APP_DIR="/root/oci-start-docker"
APP_CONTAINER_NAME="oci-start"

# Redis默认配置
REDIS_PORT="56689"
REDIS_CONFIG="/etc/redis/redis.conf"
REDIS_INFO_FILE="/etc/redis/redis_info"

# 添加路径检查函数
check_script_path() {
    # 获取脚本真实路径
    SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")

    # 更新 APP_DIR 为脚本所在目录
    if [ -z "${OCI_APP_DIR}" ]; then
        APP_DIR="$SCRIPT_PATH"
        log_info "使用脚本所在目录作为应用目录: $APP_DIR"
    else
        log_info "使用配置的应用目录: $APP_DIR"
    fi
}

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
    export REDIS_PORT=$redis_port
    export REDIS_PASSWORD_ENABLED=$password_enabled
    if [ "$password_enabled" = "true" ]; then
        export REDIS_PASSWORD=$redis_password
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
        export REDIS_PORT=$REDIS_PORT
        export REDIS_PASSWORD_ENABLED=false

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
        return 1
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

# 创建应用目录结构
create_app_structure() {
    log_info "创建应用目录结构..."
    mkdir -p $APP_DIR
    cd $APP_DIR || exit 1
    mkdir -p data logs
    log_success "目录结构创建完成"
}

# 容器删除函数
remove_container() {
    local container_name="$1"
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_info "尝试停止容器 (尝试 $attempt/$max_attempts)..."

        # 尝试正常停止容器
        if docker stop "${container_name}" >/dev/null 2>&1; then
            log_success "容器已停止"
        else
            log_warn "无法正常停止容器，尝试强制停止"
            docker kill "${container_name}" >/dev/null 2>&1
        fi

        # 等待容器完全停止
        sleep 2

        # 检查容器状态
        if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            log_success "容器已成功删除"
            return 0
        fi

        # 尝试删除容器
        log_info "尝试删除容器..."
        if docker rm -f "${container_name}" >/dev/null 2>&1; then
            log_success "容器已成功删除"
            return 0
        fi

        # 如果删除失败，获取容器详细信息
        log_warn "删除失败，容器状态："
        docker inspect "${container_name}" --format='{{.State.Status}}' 2>/dev/null || echo "无法获取容器状态"

        attempt=$((attempt + 1))
        if [ $attempt -le $max_attempts ]; then
            log_info "等待 5 秒后重试..."
            sleep 5
        fi
    done

    # 如果所有尝试都失败了，提供详细信息和手动删除建议
    log_error "在 $max_attempts 次尝试后仍无法删除容器"
    echo -e "\n${YELLOW}请尝试以下步骤手动删除：${NC}"
    echo -e "1. 查看容器状态：${GREEN}docker ps -a | grep ${container_name}${NC}"
    echo -e "2. 强制停止容器：${GREEN}docker kill ${container_name}${NC}"
    echo -e "3. 强制删除容器：${GREEN}docker rm -f ${container_name}${NC}"
    echo -e "4. 如果还是无法删除，重启 Docker 服务：${GREEN}systemctl restart docker${NC}"
    return 1
}

# 部署应用
deploy_app() {
    log_info "开始部署Docker应用..."

    # 检查并处理已存在的容器
    if docker ps -a | grep -q "$APP_CONTAINER_NAME"; then
        log_warn "发现已存在的容器，正在停止和删除..."
        if ! remove_container "$APP_CONTAINER_NAME"; then
            return 1
        fi
        sleep 2
    fi

    # 检查并拉取最新镜像
    log_info "拉取最新镜像..."
    if ! docker pull lovele/oci-start-test:latest; then
        log_error "拉取镜像失败"
        return 1
    fi

    # 准备环境变量
    local redis_env="-e SPRING_REDIS_HOST=localhost -e SPRING_REDIS_PORT=$REDIS_PORT"
    if [ "$REDIS_PASSWORD_ENABLED" = "true" ] && [ ! -z "$REDIS_PASSWORD" ]; then
        redis_env="$redis_env -e SPRING_REDIS_PASSWORD=$REDIS_PASSWORD -e SPRING_REDIS_PASSWORD_ENABLED=true"
    else
        redis_env="$redis_env -e SPRING_REDIS_PASSWORD_ENABLED=false"
    fi

    # 启动容器
    log_info "启动容器..."
    if docker run -d \
        --name "$APP_CONTAINER_NAME" \
        -p 9856:9856 \
        -v "$APP_DIR/data:/oci-start/data" \
        -v "$APP_DIR/logs:/oci-start/logs" \
        -v "$APP_DIR/docker.sh:/oci-start/docker.sh" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /usr/bin/docker:/usr/bin/docker \
        -e SERVER_PORT=9856 \
        -e OCI_APP_DIR=/oci-start \
        -e DATA_PATH=/oci-start/data \
        -e LOG_HOME=/oci-start/logs \
        $redis_env \
        --network host \
        --rm \
        lovele/oci-start:latest; then

        log_success "Docker应用部署成功"

        # 等待容器启动
        sleep 5

        # 验证容器运行状态
        if ! docker ps | grep -q "$APP_CONTAINER_NAME"; then
            log_error "容器未能正常运行，请检查日志"
            docker logs "$APP_CONTAINER_NAME"
            return 1
        fi

        # 获取系统IP
        IP=$(hostname -I | awk '{print $1}')
        if [ -z "$IP" ]; then
            IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
        fi

        # 显示访问信息
        echo -e "${BLUE}欢迎使用oci-start${NC}"
        echo -e "${CYAN}访问地址为: ${NC}http://${IP}:9856"

        # 显示Redis配置信息
        if [ -f "$REDIS_INFO_FILE" ]; then
            echo -e "\n${BLUE}Redis配置信息：${NC}"
            echo -e "${CYAN}地址:${NC} localhost"
            echo -e "${CYAN}端口:${NC} ${REDIS_PORT}"
            if [ "$REDIS_PASSWORD_ENABLED" = "true" ]; then
                echo -e "${CYAN}密码认证:${NC} 已启用"
                echo -e "${CYAN}密码:${NC} ${REDIS_PASSWORD}"
            else
                echo -e "${CYAN}密码认证:${NC} 未启用"
            fi
        fi

        # 显示容器日志
        echo -e "\n${YELLOW}容器启动日志:${NC}"
        docker logs --tail 10 "$APP_CONTAINER_NAME"
        return 0
    else
        log_error "Docker应用部署失败"
        return 1
    fi
}

# 卸载函数
uninstall() {
    local app_dir="/root/oci-start-docker"
    local container_name="oci-start"

    # 保存现有Redis配置信息（如果需要的话）
    if [ -f "$REDIS_INFO_FILE" ]; then
        cp "$REDIS_INFO_FILE" "${REDIS_INFO_FILE}.backup"
    fi

    # 显示确认提示
    echo -e "${YELLOW}===== 卸载确认 =====${NC}"
    echo -e "即将执行以下操作:"
    echo -e "1. 停止并删除 Docker 容器"
    echo -e "2. 删除 Docker 镜像"
    echo -e "3. 保留数据目录: ${app_dir}/data"
    echo -e "4. Redis 服务和数据将保持不变"
    echo -e "\n${RED}注意: 此操作无法撤销${NC}"
    echo -ne "\n${YELLOW}是否继续? [y/N]: ${NC}"

    read -r response
    case "$response" in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            log_info "已取消卸载操作"
            return 0
            ;;
    esac

    # 处理Docker容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_info "发现正在运行的容器，准备清理..."
        if ! remove_container "${container_name}"; then
            log_error "容器清理失败"
            exit 1
        fi
    else
        log_info "未发现运行中的Docker容器"
    fi

    # 处理应用数据
    if [ -d "${app_dir}" ]; then
        log_info "处理应用目录..."
# 保护数据目录
        if [ -d "${app_dir}/data" ]; then
            log_info "保护数据目录..."
            local temp_data_dir="/tmp/oci-start-data-backup"
            mv "${app_dir}/data" "${temp_data_dir}"

            if [ $? -ne 0 ]; then
                log_error "备份数据目录失败"
                return 1
            fi
        fi

        # 删除应用目录
        log_info "删除应用目录: ${app_dir}"
        rm -rf "${app_dir}"

        # 恢复数据目录
        if [ -d "${temp_data_dir}" ]; then
            log_info "恢复数据目录..."
            mkdir -p "${app_dir}"
            mv "${temp_data_dir}" "${app_dir}/data"
            if [ $? -eq 0 ]; then
                log_success "数据目录已恢复到: ${app_dir}/data"
            else
                log_error "恢复数据目录失败，备份在: ${temp_data_dir}"
                return 1
            fi
        fi
    else
        log_warn "应用目录不存在: ${app_dir}"
    fi

    # 清理Docker镜像
    log_info "清理Docker镜像..."
    if docker images | grep -q "lovele/oci-start"; then
        docker rmi "$(docker images lovele/oci-start -q)" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_success "Docker镜像已删除"
        else
            log_warn "Docker镜像删除失败，可能正被其他容器使用"
        fi
    else
        log_info "未发现相关Docker镜像"
    fi

    log_success "==========================="
    log_success "应用卸载已完成!"
    echo -e "\n${GREEN}保留的内容:${NC}"
    echo -e "1. Redis服务和数据完整保留"
    echo -e "2. 应用数据目录: ${app_dir}/data"
    if [ -f "${REDIS_INFO_FILE}.backup" ]; then
        mv "${REDIS_INFO_FILE}.backup" "$REDIS_INFO_FILE"
        echo -e "3. Redis配置信息已恢复"
    fi
    echo -e "\n${YELLOW}如需重新安装应用，请使用:${NC}"
    echo -e "   ./docker.sh install\n"
}

# 检查Docker是否已安装
check_docker() {
        if ! command -v docker &> /dev/null; then
            log_error "Docker未安装，请先安装Docker"
            return 1
        fi

        # 在容器内，我们只需要检查 docker 命令是否可用，不需要检查服务
        if docker info >/dev/null 2>&1; then
            log_success "Docker可用"
            return 0
        else
            log_error "Docker守护进程无响应，请检查Docker Socket挂载"
            return 1
        fi

    log_success "Docker服务运行正常"
    return 0
}

# 更新函数 - 拉取最新镜像并重启容器
update() {
    log_info "开始更新Docker镜像..."

    # 检查并拉取最新镜像
    log_info "拉取最新镜像..."
    if ! docker pull lovele/oci-start:latest; then
        log_error "拉取镜像失败"
        return 1
    fi

    log_success "Docker镜像更新成功!"

    # 重启容器
    log_info "重启容器使用新镜像..."
    if docker restart "$APP_CONTAINER_NAME"; then
        log_success "容器重启成功！"

        # 等待容器启动
        sleep 5

        # 验证容器运行状态
        if docker ps | grep -q "$APP_CONTAINER_NAME"; then
            log_success "容器已成功重启并运行"
            return 0
        else
            log_error "容器重启后未能正常运行"
            return 1
        fi
    else
        log_error "容器重启失败"
        return 1
    fi
}

# 显示使用帮助
show_help() {
    echo -e "${YELLOW}使用方法:${NC}"
    echo -e "  $0 ${GREEN}install${NC}    安装并部署应用"
    echo -e "  $0 ${RED}uninstall${NC}  卸载应用(保留Redis及数据)"
    echo -e "  $0 ${BLUE}update${NC}     更新Docker镜像"
}

# 主流程
main() {

    # 首先检查和设置路径
      check_script_path
    # 检查Docker安装状态
    if ! check_docker; then
        exit 1
    fi

    case "$1" in
        "install")
            # 检查Redis状态并安装/配置
            setup_redis

            # 创建应用目录结构
            create_app_structure

            # 部署应用
            deploy_app

            if [ $? -eq 0 ]; then
                log_success "全部部署完成！"
            else
                log_error "部署过程中出现错误，请检查以上日志"
                exit 1
            fi
            ;;
        "uninstall")
            uninstall
            ;;
        "update")
            update
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# 检查是否以root权限运行
if [ "$(id -u)" != "0" ]; then
    log_error "此脚本需要root权限运行"
    exit 1
fi

# 执行主流程
main "$@"
