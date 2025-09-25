#!/bin/bash

# Linux系统初始化脚本 - 支持Ubuntu和Debian（国内网络优化版）
# 作者: doubleDimple (优化版)
# 功能: 修复源配置、安装必要组件、设置上海时区、配置彩色命令行、安装Docker
# 优化: 使用国内镜像源，加速下载和安装

set -e  # 遇到错误时退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_warn "检测到以root用户运行"
        log_info "脚本将继续执行..."
    fi
}

# 检测系统类型
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        log_info "检测到系统: $OS $VER"
        
        case $ID in
            ubuntu|debian)
                PACKAGE_MANAGER="apt"
                ;;
            *)
                log_error "不支持的系统: $ID"
                exit 1
                ;;
        esac
    else
        log_error "无法检测系统类型"
        exit 1
    fi
}

# 配置Ubuntu国内镜像源
setup_ubuntu_mirrors() {
    log_step "配置Ubuntu国内镜像源..."
    
    # 备份原始sources.list
    if [[ -f /etc/apt/sources.list ]]; then
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
        log_info "已备份原始sources.list"
    fi
    
    # 获取版本代号
    VERSION_CODENAME=$(lsb_release -cs)
    log_info "检测到Ubuntu版本: $VERSION_CODENAME"
    
    # 配置阿里云镜像源
    log_info "配置阿里云Ubuntu镜像源..."
    sudo tee /etc/apt/sources.list > /dev/null <<EOF
# 阿里云Ubuntu镜像源
deb http://mirrors.aliyun.com/ubuntu/ $VERSION_CODENAME main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ $VERSION_CODENAME main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ $VERSION_CODENAME-security main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ $VERSION_CODENAME-security main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ $VERSION_CODENAME-updates main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ $VERSION_CODENAME-updates main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ $VERSION_CODENAME-backports main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ $VERSION_CODENAME-backports main restricted universe multiverse
EOF
    
    log_info "已配置Ubuntu阿里云镜像源"
}

# 修复Debian源配置（国内优化版）
fix_debian_sources() {
    log_step "配置Debian国内镜像源..."
    
    # 备份原始sources.list
    if [[ -f /etc/apt/sources.list ]]; then
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
        log_info "已备份原始sources.list"
    fi
    
    # 获取版本代号
    VERSION_CODENAME=$(lsb_release -cs)
    log_info "检测到Debian版本: $VERSION_CODENAME"
    
    # 配置中科大镜像源
    log_info "配置中科大Debian镜像源..."
    sudo tee /etc/apt/sources.list > /dev/null <<EOF
# 中科大Debian镜像源
deb https://mirrors.ustc.edu.cn/debian/ $VERSION_CODENAME main contrib non-free
deb-src https://mirrors.ustc.edu.cn/debian/ $VERSION_CODENAME main contrib non-free

deb https://mirrors.ustc.edu.cn/debian/ $VERSION_CODENAME-updates main contrib non-free
deb-src https://mirrors.ustc.edu.cn/debian/ $VERSION_CODENAME-updates main contrib non-free

deb https://mirrors.ustc.edu.cn/debian-security/ $VERSION_CODENAME-security main contrib non-free
deb-src https://mirrors.ustc.edu.cn/debian-security/ $VERSION_CODENAME-security main contrib non-free
EOF
    
    log_info "已配置Debian中科大镜像源"
}

# 配置镜像源（统一入口）
setup_mirrors() {
    if [[ "$ID" == "ubuntu" ]]; then
        setup_ubuntu_mirrors
    elif [[ "$ID" == "debian" ]]; then
        fix_debian_sources
    fi
    
    # 清理并更新
    sudo apt clean
    log_info "正在更新软件包列表..."
    sudo apt update -y
    log_info "软件源配置完成"
}

# 更新系统
update_system() {
    log_step "更新系统软件包..."
    sudo apt update && sudo apt upgrade -y
    log_info "系统更新完成"
}

# 安装必要组件
install_packages() {
    log_step "安装必要组件..."
    
    # 基础工具
    local packages=(
        "curl"
        "wget" 
        "git"
        "vim"
        "nano"
        "htop"
        "tree"
        "unzip"
        "zip"
        "net-tools"
        "dnsutils"
        "build-essential"
        "software-properties-common"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"
    )
    
    for package in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii  $package "; then
            log_info "$package 已安装"
        else
            log_info "安装 $package..."
            sudo apt install -y "$package"
        fi
    done
    
    log_info "软件包安装完成"
}

# 清理Docker配置
clean_docker_repos() {
    log_info "清理可能存在的错误Docker仓库配置..."
    
    # 删除可能存在的Docker仓库文件
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/sources.list.d/docker.list.save
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    sudo rm -f /usr/share/keyrings/docker.gpg
    
    log_info "Docker仓库配置清理完成"
}

# 安装Docker（国内优化版）
install_docker() {
    log_step "检查并安装Docker..."
    
    if command -v docker &> /dev/null; then
        log_info "Docker已安装，版本: $(docker --version)"
        return 0
    else
        log_info "安装Docker（使用国内镜像）..."
        
        # 首先清理可能存在的错误配置
        clean_docker_repos
        
        # 确保源配置正确后再安装Docker
        log_info "准备Docker安装环境..."
        sudo apt update -y
        
        # 安装必要的依赖
        sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
        
        # 根据系统类型设置正确的仓库（使用阿里云镜像）
        if [[ "$ID" == "ubuntu" ]]; then
            # Ubuntu系统 - 使用阿里云Docker镜像
            log_info "配置Ubuntu Docker阿里云仓库..."
            
            # 添加Docker官方GPG密钥（通过阿里云镜像）
            curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
            
            # 添加Docker仓库
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
        elif [[ "$ID" == "debian" ]]; then
            # Debian系统 - 使用阿里云Docker镜像
            log_info "配置Debian Docker阿里云仓库..."
            
            # 添加Docker官方GPG密钥（通过阿里云镜像）
            curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
            
            # 添加Docker仓库
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
        else
            log_error "不支持的系统类型: $ID"
            return 1
        fi
        
        # 更新包索引
        log_info "更新软件包列表..."
        sudo apt update -y
        
        # 安装Docker
        log_info "安装Docker Engine..."
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        # 将当前用户添加到docker组（如果不是root用户）
        if [[ $EUID -ne 0 ]]; then
            sudo usermod -aG docker $USER
            log_info "已将用户 $USER 添加到docker组"
            log_warn "请重新登录或运行 'newgrp docker' 使docker组权限生效"
        fi
        
        # 启用并启动Docker服务
        sudo systemctl enable docker
        sudo systemctl start docker
        
        # 配置Docker镜像加速器（阿里云）
        setup_docker_mirrors
        
        # 验证安装
        if command -v docker &> /dev/null; then
            log_info "Docker安装完成，版本: $(docker --version)"
        else
            log_error "Docker安装失败"
            return 1
        fi
    fi
}

# 配置Docker镜像加速器
setup_docker_mirrors() {
    log_step "配置Docker镜像加速器..."
    
    # 创建docker目录
    sudo mkdir -p /etc/docker
    
    # 配置镜像加速器（多个国内镜像源）
    sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
    "registry-mirrors": [
        "https://docker.mirrors.ustc.edu.cn",
        "https://hub-mirror.c.163.com",
        "https://mirror.baidubce.com",
        "https://ccr.ccs.tencentyun.com"
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    },
    "storage-driver": "overlay2"
}
EOF
    
    log_info "Docker镜像加速器配置完成"
    
    # 重启Docker服务使配置生效
    if systemctl is-active --quiet docker; then
        log_info "重启Docker服务..."
        sudo systemctl daemon-reload
        sudo systemctl restart docker
        log_info "Docker服务已重启"
    fi
}

# 安装Docker Compose（使用国内源）
install_docker_compose() {
    log_step "检查Docker Compose..."
    
    # 检查docker compose插件（新版本）
    if docker compose version &> /dev/null; then
        log_info "Docker Compose Plugin已安装，版本: $(docker compose version)"
        return 0
    fi
    
    # 检查独立的docker-compose（旧版本）
    if command -v docker-compose &> /dev/null; then
        log_info "Docker Compose已安装，版本: $(docker-compose --version)"
        return 0
    fi
    
    # 如果都没有，从GitHub加速镜像安装独立版本
    log_info "安装Docker Compose独立版本（使用GitHub加速）..."
    
    # 使用GitHub镜像站获取最新版本
    DOCKER_COMPOSE_VERSION=$(curl -s https://ghproxy.com/https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
    
    if [[ -z "$DOCKER_COMPOSE_VERSION" ]]; then
        log_warn "无法获取最新版本，使用默认版本"
        DOCKER_COMPOSE_VERSION="v2.24.0"
    fi
    
    log_info "下载Docker Compose $DOCKER_COMPOSE_VERSION（通过GitHub加速）..."
    
    # 使用GitHub加速镜像下载Docker Compose
    sudo curl -L "https://ghproxy.com/https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    
    # 添加执行权限
    sudo chmod +x /usr/local/bin/docker-compose
    
    # 验证安装
    if command -v docker-compose &> /dev/null; then
        log_info "Docker Compose安装完成，版本: $(docker-compose --version)"
    else
        log_error "Docker Compose安装失败"
        return 1
    fi
}

# 设置上海时区
set_timezone() {
    log_step "设置时区为Asia/Shanghai..."
    
    current_tz=$(timedatectl show --property=Timezone --value)
    if [[ "$current_tz" == "Asia/Shanghai" ]]; then
        log_info "时区已经是Asia/Shanghai"
    else
        sudo timedatectl set-timezone Asia/Shanghai
        log_info "时区设置完成"
    fi
    
    # 显示当前时间
    log_info "当前时间: $(date)"
}

# 配置彩色命令行
setup_colorful_terminal() {
    log_step "配置彩色命令行..."
    
    # 备份原始.bashrc
    if [[ -f ~/.bashrc ]]; then
        cp ~/.bashrc ~/.bashrc.backup.$(date +%Y%m%d_%H%M%S)
        log_info "已备份原始.bashrc文件"
    fi
    
    # 检查是否已经启用了彩色提示符
    if grep -q "force_color_prompt=yes" ~/.bashrc; then
        log_info "彩色提示符已启用"
    else
        # 取消注释 force_color_prompt=yes
        if grep -q "#force_color_prompt=yes" ~/.bashrc; then
            sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/' ~/.bashrc
            log_info "已启用force_color_prompt"
        fi
    fi
    
    # 检查是否已经添加过自定义配置
    if grep -q "自定义彩色配置 (由init.sh添加)" ~/.bashrc; then
        log_info "自定义彩色配置已存在"
    else
        # 添加自定义彩色配置
        cat >> ~/.bashrc << 'EOF'

# === 自定义彩色配置 (由init.sh添加) ===
# 启用彩色提示符
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# 启用ls颜色和扩展命令
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias lh='ls -lah --color=auto'  # 人类可读的长格式
alias lt='ls -ltr --color=auto'  # 按时间排序
alias lS='ls -lSr --color=auto'  # 按大小排序

# 启用grep颜色
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# 其他有用的别名和命令
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias h='history'
alias c='clear'
alias cls='clear'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ps='ps aux'
alias top='htop'
alias mkdir='mkdir -pv'
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias grep='grep -n --color=auto'
alias which='which -a'
alias path='echo -e ${PATH//:/\\n}'

# Docker相关别名
alias dps='docker ps'
alias dpsa='docker ps -a'
alias di='docker images'
alias dc='docker compose'
alias dcup='docker compose up -d'
alias dcdown='docker compose down'
alias dclogs='docker compose logs -f'
alias dcps='docker compose ps'

# 传统docker-compose别名（兼容性）
alias docker-compose-up='docker-compose up -d'
alias docker-compose-down='docker-compose down'
alias docker-compose-logs='docker-compose logs -f'

# Git 加速配置
git config --global url."https://ghproxy.com/https://github.com".insteadOf "https://github.com"

EOF
        log_info "自定义彩色配置添加完成"
    fi
}

# 配置系统优化
setup_system_optimization() {
    log_step "配置系统优化..."
    
    # 配置pip国内源
    if command -v pip3 &> /dev/null || command -v pip &> /dev/null; then
        log_info "配置pip国内源..."
        mkdir -p ~/.pip
        cat > ~/.pip/pip.conf << 'EOF'
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com
EOF
        log_info "pip国内源配置完成"
    fi
    
    # 配置npm国内源
    if command -v npm &> /dev/null; then
        log_info "配置npm国内源..."
        npm config set registry https://registry.npmmirror.com
        log_info "npm国内源配置完成"
    fi
    
    # 配置yarn国内源
    if command -v yarn &> /dev/null; then
        log_info "配置yarn国内源..."
        yarn config set registry https://registry.npmmirror.com
        log_info "yarn国内源配置完成"
    fi
}

# 测试Docker安装
test_docker() {
    log_step "测试Docker安装..."
    
    if command -v docker &> /dev/null; then
        log_info "运行Docker测试..."
        if sudo docker run --rm hello-world &> /dev/null; then
            log_info "Docker测试成功！"
        else
            log_warn "Docker测试未通过，但Docker已安装"
        fi
        
        # 测试镜像加速器
        log_info "测试Docker镜像加速器..."
        docker_info=$(sudo docker info 2>/dev/null | grep -A 10 "Registry Mirrors")
        if [[ -n "$docker_info" ]]; then
            log_info "Docker镜像加速器已生效"
        else
            log_warn "Docker镜像加速器可能未生效"
        fi
    else
        log_warn "Docker未安装，跳过测试"
    fi
}

# 显示完成信息
show_completion() {
    echo
    log_info "======================================"
    log_info "系统初始化完成！（国内网络优化版）"
    log_info "======================================"
    echo
    log_info "已完成的配置:"
    
    if [[ "$ID" == "debian" ]]; then
        echo "  ✓ Debian中科大镜像源配置"
    elif [[ "$ID" == "ubuntu" ]]; then
        echo "  ✓ Ubuntu阿里云镜像源配置"
    fi
    echo "  ✓ 系统软件包更新"
    echo "  ✓ 必要组件安装"
    
    if command -v docker &> /dev/null; then
        echo "  ✓ Docker安装成功（阿里云镜像）"
        echo "  ✓ Docker镜像加速器配置"
    else
        echo "  ✗ Docker安装失败"
    fi
    
    if docker compose version &> /dev/null || command -v docker-compose &> /dev/null; then
        echo "  ✓ Docker Compose可用"
    else
        echo "  ✗ Docker Compose不可用"
    fi
    
    echo "  ✓ 时区设置为Asia/Shanghai"
    echo "  ✓ 彩色命令行配置"
    echo "  ✓ 系统优化配置（pip、npm源等）"
    echo "  ✓ Git GitHub加速配置"
    echo
    
    log_warn "请运行以下命令使配置生效:"
    echo "  source ~/.bashrc"
    if [[ $EUID -ne 0 ]] && command -v docker &> /dev/null; then
        echo "  newgrp docker  # 或重新登录以使docker组权限生效"
    fi
    echo
    log_warn "或者重新登录系统"
    echo
    
    # 显示版本信息
    log_info "安装的软件版本:"
    if command -v docker &> /dev/null; then
        echo "  Docker: $(docker --version)"
        
        # 检查Docker服务状态
        if systemctl is-active --quiet docker; then
            echo "  Docker服务: ✓ 运行中"
        else
            echo "  Docker服务: ✗ 未运行"
        fi
    else
        echo "  Docker: ✗ 未安装"
    fi
    
    if docker compose version &> /dev/null; then
        echo "  Docker Compose Plugin: $(docker compose version --short)"
    elif command -v docker-compose &> /dev/null; then
        echo "  Docker Compose: $(docker-compose --version)"
    else
        echo "  Docker Compose: ✗ 不可用"
    fi
    
    echo
    log_info "系统时间信息:"
    echo "  当前时间: $(date)"
    echo "  时区: $(timedatectl show --property=Timezone --value)"
    echo
    
    log_info "国内网络优化："
    echo "  ✓ 系统软件源：国内镜像源"
    echo "  ✓ Docker镜像：中科大、网易、百度、腾讯云加速"
    echo "  ✓ GitHub加速：ghproxy代理"
    echo "  ✓ pip源：阿里云镜像"
    echo "  ✓ npm源：淘宝镜像"
    echo
    
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        log_info "Docker快速使用指南:"
        echo "  sudo docker run hello-world     # 测试Docker"
        echo "  docker ps                       # 查看运行的容器"
        echo "  docker images                   # 查看镜像"
        echo "  docker compose up -d            # 启动compose服务"
        echo "  docker pull nginx               # 测试镜像加速器"
    else
        log_warn "Docker安装或启动失败，请检查错误信息"
        log_info "可以尝试手动启动Docker:"
        echo "  sudo systemctl start docker"
        echo "  sudo systemctl enable docker"
    fi
    echo
}

# 主函数
main() {
    log_info "开始Linux系统初始化（国内网络优化版）..."
    echo
    
    check_root
    detect_system
    
    echo
    log_info "将自动执行以下操作（国内网络优化）:"
    if [[ "$ID" == "debian" ]]; then
        echo "  • 配置Debian中科大镜像源"
    elif [[ "$ID" == "ubuntu" ]]; then
        echo "  • 配置Ubuntu阿里云镜像源"
    fi
    echo "  • 系统软件包更新"
    echo "  • 必要组件安装"
    echo "  • Docker安装（阿里云镜像源）"
    echo "  • Docker镜像加速器配置"
    echo "  • Docker Compose安装（GitHub加速）"
    echo "  • 时区设置为Asia/Shanghai"
    echo "  • 彩色命令行配置"
    echo "  • 系统优化配置（pip、npm、git等加速）"
    echo
    
    setup_mirrors
    echo
    update_system
    echo
    install_packages
    echo
    install_docker
    echo
    install_docker_compose
    echo
    set_timezone
    echo
    setup_colorful_terminal
    echo
    setup_system_optimization
    echo
    test_docker
    echo
    show_completion
}

# 执行主函数
main "$@"
