#!/bin/bash

# =========================================================
# 作者: doubleDimple
# 项目: OCI-Start Docker 管理脚本
# 版本: v1.2
# 描述: 一键部署、更新、卸载 OCI-Start 应用
#
# --- 使用步骤 ---
# 1. 下载脚本并赋予权限:
#    chmod +x docker.sh
#
# 2. 安装应用 (默认端口 9856):
#    ./docker.sh install
#    或者指定端口:
#    ./docker.sh install -p 8080
#
# 3. 更新应用 (自动保留数据):
#    ./docker.sh update
#
# 4. 卸载应用 (保留脚本本身):
#    ./docker.sh uninstall
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_DIR="${OCI_APP_DIR:-/root/oci-start-docker}"
APP_CONTAINER_NAME="oci-start"
SCRIPT_PATH=$(realpath "$0")
SYMLINK_PATH="/usr/local/bin/oci-start-docker"

DEFAULT_PORT=9856
CUSTOM_PORT=$DEFAULT_PORT
PORT_SPECIFIED=false

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

# 获取公网IP函数
get_public_ip() {
    local ip=""
    ip=$(curl -s --connect-timeout 3 -4 ifconfig.me 2>/dev/null)
    
    if [ -z "$ip" ]; then
        ip=$(curl -s --connect-timeout 3 -4 icanhazip.com 2>/dev/null)
    fi

    if [ -z "$ip" ]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    
    if [ -z "$ip" ]; then
        ip=$(ip route get 1 | awk '{print $(NF-2);exit}')
    fi
    
    echo "$ip"
}

parse_args() {
    local args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
        arg="${args[i]}"
        next_arg="${args[i+1]}"
        
        if [[ "$arg" == "-p" || "$arg" == "--port" ]]; then
            if [ -z "$next_arg" ]; then
                log_error "缺少端口号参数"
                exit 1
            fi
            
            if ! [ "$next_arg" -eq "$next_arg" ] 2>/dev/null; then
                log_error "端口参数无效"
                exit 1
            fi
            
            if [ "$next_arg" -ge 1 ] && [ "$next_arg" -le 65535 ]; then
                CUSTOM_PORT="$next_arg"
                PORT_SPECIFIED=true
                return 0
            else
                log_error "端口参数无效"
                exit 1
            fi
        fi
    done
    return 0
}

get_container_port() {
    if docker ps --format '{{.Names}}' | grep -q "^${APP_CONTAINER_NAME}$"; then
        local env_port=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$APP_CONTAINER_NAME" | grep "^SERVER_PORT=" | cut -d= -f2)
        
        if [ -n "$env_port" ] && [ "$env_port" -eq "$env_port" ] 2>/dev/null; then
            echo "$env_port"
        fi
    fi
}

install_websockify() {
    log_info "检查依赖环境 (websockify)..."
    
    if command -v websockify &> /dev/null; then
        return 0
    fi
    
    if python3 -c "import websockify" &> /dev/null || python -c "import websockify" &> /dev/null; then
        return 0
    fi
    
    log_warn "正在安装 websockify..."
    
    local install_success=false
    
    if command -v apt &> /dev/null; then
        if apt update -y && apt install -y websockify; then
            if command -v websockify &> /dev/null; then
                install_success=true
            fi
        fi
    fi
    
    if [ "$install_success" = false ] && command -v yum &> /dev/null; then
        if yum install -y python3-websockify || yum install -y websockify; then
            if command -v websockify &> /dev/null; then
                install_success=true
            fi
        fi
    fi
    
    if [ "$install_success" = false ]; then
        if ! command -v pip3 &> /dev/null && ! command -v pip &> /dev/null; then
            if command -v apt &> /dev/null; then
                apt install -y python3-pip
            elif command -v yum &> /dev/null; then
                yum install -y python3-pip
            fi
        fi
        
        local pip_cmd=""
        if command -v pip3 &> /dev/null; then
            pip_cmd="pip3"
        elif command -v pip &> /dev/null; then
            pip_cmd="pip"
        fi
        
        if [ -n "$pip_cmd" ]; then
            if $pip_cmd install websockify; then
                if command -v websockify &> /dev/null || python3 -c "import websockify" &> /dev/null; then
                    install_success=true
                fi
            fi
        fi
    fi
    
    if [ "$install_success" = false ]; then
        if ! command -v git &> /dev/null; then
            if command -v apt &> /dev/null; then
                apt install -y git
            elif command -v yum &> /dev/null; then
                yum install -y git
            fi
        fi
        
        if command -v git &> /dev/null; then
            local temp_dir="/tmp/websockify-install"
            rm -rf "$temp_dir"
            
            if git clone https://github.com/novnc/websockify "$temp_dir"; then
                cd "$temp_dir"
                if python3 setup.py install || python setup.py install; then
                    install_success=true
                fi
                cd - > /dev/null
                rm -rf "$temp_dir"
            fi
        fi
    fi
    
    if [ "$install_success" = true ]; then
        return 0
    else
        log_error "websockify安装失败，可能会影响部分功能"
        return 1
    fi
}

create_symlink() {
    if [ ! -L "$SYMLINK_PATH" ] || [ "$(readlink "$SYMLINK_PATH")" != "$SCRIPT_PATH" ]; then
        mkdir -p "$(dirname "$SYMLINK_PATH")" 2>/dev/null
        if ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH" 2>/dev/null; then
            log_success "系统命令已创建: oci-start-docker"
        else
            if command -v sudo &>/dev/null; then
                sudo ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH"
            fi
        fi
    fi
}

install_docker() {
    log_info "正在安装 Docker..."
    
    if apt update -y && apt install -y curl && curl -fsSL https://get.docker.com | bash -s docker; then
        true
    else
        return 1
    fi
    
    systemctl start docker &> /dev/null || service docker start &> /dev/null
    systemctl enable docker &> /dev/null || true
    
    sleep 3
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        return 0
    else
        service docker start &> /dev/null || systemctl start docker &> /dev/null
        sleep 5
        
        if docker info &> /dev/null; then
            return 0
        else
            return 1
        fi
    fi
}

check_script_path() {
    SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")

    if [ -z "${OCI_APP_DIR}" ]; then
        APP_DIR="$SCRIPT_PATH"
    fi
}

create_app_structure() {
    mkdir -p $APP_DIR
    cd $APP_DIR || exit 1
    mkdir -p data logs
}

remove_container() {
    local container_name="$1"
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if docker stop "${container_name}" >/dev/null 2>&1; then
            true
        else
            docker kill "${container_name}" >/dev/null 2>&1
        fi

        sleep 2

        if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            return 0
        fi

        if docker rm -f "${container_name}" >/dev/null 2>&1; then
            return 0
        fi

        attempt=$((attempt + 1))
        if [ $attempt -le $max_attempts ]; then
            sleep 5
        fi
    done

    return 1
}

deploy_app() {
    log_info "部署应用 (端口: $CUSTOM_PORT)..."

    if docker ps -a | grep -q "$APP_CONTAINER_NAME"; then
        log_info "清理旧容器..."
        if ! remove_container "$APP_CONTAINER_NAME"; then
            return 1
        fi
        sleep 2
    fi

    log_info "拉取镜像 lovele/oci-start:latest..."
    if ! docker pull lovele/oci-start:latest; then
        return 1
    fi

    log_info "启动容器..."
    if docker run -d \
        --name "$APP_CONTAINER_NAME" \
        -p "${CUSTOM_PORT}:${CUSTOM_PORT}" \
        -v "$APP_DIR/data:/oci-start/data" \
        -v "$APP_DIR/logs:/oci-start/logs" \
        -v "$APP_DIR/docker.sh:/oci-start/docker.sh" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /usr/bin/docker:/usr/bin/docker \
        -e SERVER_PORT="${CUSTOM_PORT}" \
        -e OCI_APP_DIR=/oci-start \
        -e DATA_PATH=/oci-start/data \
        -e LOG_HOME=/oci-start/logs \
        --network host \
        --restart always \
        lovele/oci-start:latest; then

        log_success "部署成功"
        sleep 5

        if ! docker ps | grep -q "$APP_CONTAINER_NAME"; then
            docker logs "$APP_CONTAINER_NAME"
            return 1
        fi

        local PUBLIC_IP=$(get_public_ip)
        echo -e "${CYAN}访问地址: ${NC}http://${PUBLIC_IP}:${CUSTOM_PORT}"
        return 0
    else
        return 1
    fi
}

uninstall() {
    local app_dir="${APP_DIR}"
    local container_name="$APP_CONTAINER_NAME"

    echo -ne "${YELLOW}确认卸载? [y/N]: ${NC}"
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            return 0
            ;;
    esac
    
    log_info "开始执行卸载流程..."

    # 1. 删除容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_info "正在停止并删除容器: ${container_name}..."
        if ! remove_container "${container_name}"; then
            log_error "删除容器失败"
            exit 1
        fi
    fi

    # 2. 处理数据目录 (不再删除整个APP目录，以保护脚本)
    if [ -d "${app_dir}/data" ]; then
        local temp_data_dir="/tmp/oci-start-data-backup"
        log_info "正在临时备份数据至: ${temp_data_dir}..."
        mv "${app_dir}/data" "${temp_data_dir}"

        if [ $? -ne 0 ]; then
            log_error "备份数据失败"
            return 1
        fi
    fi

    log_info "正在清理运行日志..."
    rm -rf "${app_dir}/logs"

    # 如果有备份，还原备份，但不要删除 app_dir 目录本身，防止删除了脚本
    if [ -d "${temp_data_dir}" ]; then
        log_info "正在还原数据目录至 ${app_dir}/data ..."
        mkdir -p "${app_dir}"
        mv "${temp_data_dir}" "${app_dir}/data"
        if [ $? -ne 0 ]; then
            log_error "还原数据失败"
            return 1
        fi
    fi

    # 3. 清理镜像
    if docker images | grep -q "lovele/oci-start"; then
        log_info "正在清理 Docker 镜像..."
        docker rmi "$(docker images lovele/oci-start -q)" >/dev/null 2>&1
    fi

    # 4. 软链接保留 (注释掉删除逻辑)
    # if [ -L "$SYMLINK_PATH" ] && [ "$(readlink "$SYMLINK_PATH")" = "$SCRIPT_PATH" ]; then
    #    log_info "正在移除系统命令软链接..."
    #    rm -f "$SYMLINK_PATH"
    # fi

    log_success "卸载完成！"
    log_info "提示: 脚本文件及数据目录已保留，您可以随时使用 ./docker.sh install 重新安装。"
}

check_docker() {
    log_info "检查Docker环境..."
    
    if command -v docker &> /dev/null; then
        if docker info >/dev/null 2>&1; then
            return 0
        else
            systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1
            sleep 3
            
            if docker info >/dev/null 2>&1; then
                return 0
            else
                true
            fi
        fi
    else
        true
    fi
    
    if install_docker; then
        return 0
    else
        log_error "Docker安装失败"
        return 1
    fi
}

update() {
    create_symlink
    log_info "开始更新..."

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${APP_CONTAINER_NAME}$"; then
        log_error "未找到容器，请先执行 install 安装"
        return 1
    fi

    if [ "$PORT_SPECIFIED" = false ]; then
        local OLD_PORT=$(get_container_port)
        if [ -n "$OLD_PORT" ]; then
            CUSTOM_PORT=$OLD_PORT
            log_info "检测到当前运行端口: $CUSTOM_PORT"
        fi
    fi

    local old_image_id=$(docker inspect "$APP_CONTAINER_NAME" --format='{{.Image}}' 2>/dev/null)

    log_info "正在拉取最新镜像..."
    if ! docker pull lovele/oci-start:latest; then
        log_error "镜像拉取失败"
        return 1
    fi

    local new_image_id=$(docker images lovele/oci-start:latest --format='{{.ID}}' | head -n1)

    if [ "$old_image_id" = "$new_image_id" ]; then
        if [ "$PORT_SPECIFIED" = false ]; then
            log_info "当前已是最新版本"
            return 0
        fi
    fi

    log_info "检测到新版本，正在重启容器..."
    if ! remove_container "$APP_CONTAINER_NAME"; then
        return 1
    fi

    sleep 3

    if docker run -d \
        --name "$APP_CONTAINER_NAME" \
        -p "${CUSTOM_PORT}:${CUSTOM_PORT}" \
        -v "$APP_DIR/data:/oci-start/data" \
        -v "$APP_DIR/logs:/oci-start/logs" \
        -v "$APP_DIR/docker.sh:/oci-start/docker.sh" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /usr/bin/docker:/usr/bin/docker \
        -e SERVER_PORT="${CUSTOM_PORT}" \
        -e OCI_APP_DIR=/oci-start \
        -e DATA_PATH=/oci-start/data \
        -e LOG_HOME=/oci-start/logs \
        --network host \
        --restart always \
        lovele/oci-start:latest; then

        log_success "更新成功"
        sleep 5

        if docker ps | grep -q "$APP_CONTAINER_NAME"; then
            if [ -n "$old_image_id" ] && [ "$old_image_id" != "$new_image_id" ]; then
                log_info "清理旧版本镜像..."
                docker rmi "$old_image_id" >/dev/null 2>&1 || true
            fi
            
            local PUBLIC_IP=$(get_public_ip)
            echo -e "${CYAN}访问地址: ${NC}http://${PUBLIC_IP}:${CUSTOM_PORT}"
            return 0
        else
            docker logs "$APP_CONTAINER_NAME"
            return 1
        fi
    else
        return 1
    fi
}

show_help() {
    echo -e "${YELLOW}使用方法:${NC}"
    echo -e "  $0 install [-p <port>]  - 安装应用"
    echo -e "  $0 update               - 更新应用"
    echo -e "  $0 uninstall            - 卸载应用"
}

main() {
    parse_args "$@"
    check_script_path
    
    SCRIPT_PATH=$(realpath "$0")

    if ! check_docker; then
        exit 1
    fi
    
    install_websockify

    case "$1" in
        "install")
            create_symlink
            create_app_structure
            deploy_app
            if [ $? -eq 0 ]; then
                log_success "安装完成"
            else
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

if [ "$(id -u)" != "0" ]; then
    log_error "需要root权限"
    exit 1
fi

main "$@"
