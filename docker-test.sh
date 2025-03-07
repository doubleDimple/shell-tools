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
#    ./docker-test.sh install
#
# 2. 指定目录安装（三种方式）：
#    a. 一次性指定：
#       OCI_APP_DIR=/root/oci-start-docker ./docker-test.sh install
#
#    b. 临时指定（仅对当前终端有效）：
#       export OCI_APP_DIR=/root/oci-start-docker
#       ./docker-test.sh install
#
#    c. 永久指定（对当前用户永久有效）：
#       echo 'export OCI_APP_DIR=/root/oci-start-docker' >> ~/.bashrc
#       source ~/.bashrc
#       ./docker-test.sh install
#
# 3. 卸载应用：
#    ./docker-test.sh uninstall


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
APP_DIR="${OCI_APP_DIR:-/root/oci-start-docker}"
APP_CONTAINER_NAME="oci-start"
DB_CONFIG_FILE="${APP_DIR}/db_config.properties"
APP_CONFIG_FILE="${APP_DIR}/data/application.yml"

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

    # 更新配置文件路径
    DB_CONFIG_FILE="${APP_DIR}/db_config.properties"
    APP_CONFIG_FILE="${APP_DIR}/data/application.yml"
}

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
        log_info "将在应用首次启动时创建，然后手动更新密码"
    fi

    log_success "数据库密码已生成并保存"
    echo "$new_password"
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

    # 生成新密码并更新配置文件
    local db_password=$(update_db_password)

    # 检查并拉取最新镜像
    log_info "拉取最新镜像..."
    if ! docker pull lovele/oci-start-test:latest; then
        log_error "拉取镜像失败"
        return 1
    fi

    # 启动容器
    log_info "启动容器..."
    if docker run -d \
        --name "$APP_CONTAINER_NAME" \
        -p 9856:9856 \
        -v "$APP_DIR/data:/oci-start/data" \
        -v "$APP_DIR/logs:/oci-start/logs" \
        -v "$APP_DIR/docker-test.sh:/oci-start/docker-test.sh" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /usr/bin/docker:/usr/bin/docker \
        -e SERVER_PORT=9856 \
        -e OCI_APP_DIR=/oci-start \
        -e DATA_PATH=/oci-start/data \
        -e LOG_HOME=/oci-start/logs \
        --network host \
        --rm \
        lovele/oci-start-test:latest; then

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

        # 显示数据库配置信息
        if [ -f "$DB_CONFIG_FILE" ]; then
            local db_password=$(grep "DB_PASSWORD" "$DB_CONFIG_FILE" | cut -d'=' -f2)
            echo -e "\n${BLUE}数据库配置信息：${NC}"
            echo -e "${CYAN}类型:${NC} H2 (内嵌数据库)"
            echo -e "${CYAN}密码状态:${NC} 已动态生成并写入配置文件"
            echo -e "${CYAN}当前密码:${NC} $db_password"
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
    local container_name="oci-start"

    # 显示确认提示
    echo -e "${YELLOW}===== 卸载确认 =====${NC}"
    echo -e "即将执行以下操作:"
    echo -e "1. 停止并删除 Docker 容器"
    echo -e "2. 删除 Docker 镜像"
    echo -e "3. 保留数据目录: ${APP_DIR}/data"
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
    if [ -d "${APP_DIR}" ]; then
        log_info "处理应用目录..."
        # 保护数据目录
        if [ -d "${APP_DIR}/data" ]; then
            log_info "保护数据目录..."
            local temp_data_dir="/tmp/oci-start-data-backup"
            mv "${APP_DIR}/data" "${temp_data_dir}"

            if [ $? -ne 0 ]; then
                log_error "备份数据目录失败"
                return 1
            fi
        fi

        # 删除应用目录
        log_info "删除应用目录: ${APP_DIR}"
        rm -rf "${APP_DIR}"

        # 恢复数据目录
        if [ -d "${temp_data_dir}" ]; then
            log_info "恢复数据目录..."
            mkdir -p "${APP_DIR}"
            mv "${temp_data_dir}" "${APP_DIR}/data"
            if [ $? -eq 0 ]; then
                log_success "数据目录已恢复到: ${APP_DIR}/data"
            else
                log_error "恢复数据目录失败，备份在: ${temp_data_dir}"
                return 1
            fi
        fi
    else
        log_warn "应用目录不存在: ${APP_DIR}"
    fi

    # 清理Docker镜像
    log_info "清理Docker镜像..."
    if docker images | grep -q "lovele/oci-start-test"; then
        docker rmi "$(docker images lovele/oci-start-test -q)" >/dev/null 2>&1
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
    echo -e "1. 应用数据目录: ${APP_DIR}/data"
    echo -e "\n${YELLOW}如需重新安装应用，请使用:${NC}"
    echo -e "   ./docker-test.sh install\n"
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
    if ! docker pull lovele/oci-start-test:latest; then
        log_error "拉取镜像失败"
        return 1
    fi

    log_success "Docker镜像更新成功!"

    # 停止现有容器
    log_info "停止现有容器..."
    if ! remove_container "$APP_CONTAINER_NAME"; then
        log_error "停止现有容器失败"
        return 1
    fi

    # 重新部署应用
    log_info "使用新镜像重新部署应用..."
    if deploy_app; then
        log_success "应用更新成功！"
        return 0
    else
        log_error "应用更新失败"
        return 1
    fi
}

# 显示使用帮助
show_help() {
    echo -e "${YELLOW}使用方法:${NC}"
    echo -e "  $0 ${GREEN}install${NC}    安装并部署应用"
    echo -e "  $0 ${RED}uninstall${NC}  卸载应用(保留数据)"
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