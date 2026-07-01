#!/bin/bash

# Linux系统初始化脚本 - 支持Ubuntu和Debian (已适配Debian 13并增强容错)
# 作者: doubleDimple (由 AI 修复容错及 Debian 13 适配)
# 功能: 修复源配置、安装必要组件、设置上海时区、配置彩色命令行、安装Docker

# 彻底移除 set -e，确保个别包失败不卡死脚本
set +e

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
        case
    else
        log_error "无法检测系统类型"
        exit 1
    fi
}

# 修复Debian源配置
fix_debian_sources() {
    log_step "修复Debian软件源配置..."
    
    if [[ "$ID" == "debian" ]]; then
        log_info "检测到Debian系统，修复源配置..."
        
        # 备份原始sources.list
        if [[ -f /etc/apt/sources.list ]]; then
            sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
            log_info "已备份原始sources.list"
        fi
        
        # 安全获取版本代号，防止 lsb_release 未安装导致脚本崩溃
        VERSION_CODENAME=${VERSION_CODENAME:-$VERSION_ID}
        if [ "$VERSION_CODENAME" = "13" ]; then
            VERSION_CODENAME="trixie"
        fi
        log_info "确定的 Debian 仓库代号为: $VERSION_CODENAME"
        
        # 配置正确的sources.list (引入 Debian 13 的 non-free-firmware 规范)
        log_info "配置Debian官方镜像源..."
        sudo tee /etc/apt/sources.list > /dev/null <<EOF
# Debian $VERSION_CODENAME repositories
deb http://deb.debian.org/debian $VERSION_CODENAME main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian $VERSION_CODENAME main contrib non-free non-free-firmware

# Debian $VERSION_CODENAME updates
deb http://deb.debian.org/debian $VERSION_CODENAME-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian $VERSION_CODENAME-updates main contrib non-free non-free-firmware

# Debian $VERSION_CODENAME security updates
deb http://security.debian.org/debian-security $VERSION_CODENAME-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security $VERSION_CODENAME-security main contrib non-free non-free-firmware
EOF
        
        log_info "已修复Debian源配置"
        
        # 清理并更新，允许单步失败
        sudo apt clean || true
        sudo apt update -y || true
        log_info "软件源更新完成"
    fi
}

# 更新系统
update_system() {
    log_step "更新系统软件包..."
    # 避免 upgrade 锁死交互，加上 || true 容错
    sudo apt update && sudo apt upgrade -y || log_warn "系统全面更新期间有部分依赖未完全升级，跳过继续。"
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
            # 关键改动：加入 --ignore-missing，且即使失败 (|| true) 也不中断循环
            sudo apt install -y --ignore-missing "$package" || log_warn "未能装上 $package，可能当前系统版本仓库无此组件，跳过。"
        fi
    done
    
    log_info "软件包安装处理完成"
}

# 清理Docker配置
clean_docker_repos() {
    log_info "清理可能存在的错误Docker仓库配置..."
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/sources.list.d/docker.list.save
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    log_info "Docker仓库配置清理完成"
}

# 安装Docker
install_docker() {
    log_step "检查并安装Docker..."
    
    if command -v docker &> /dev/null; then
        log_info "Docker已安装，版本: $(docker --version)"
        return 0
    else
        log_info "安装Docker..."
        clean_docker_repos
        
        log_info "准备Docker安装环境..."
        sudo apt update -y || true
        
        # 兜底安装依赖
        sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release --ignore-missing || true
        
        # 根据系统类型设置正确的仓库
        if [[ "$ID" == "ubuntu" ]]; then
            log_info "配置Ubuntu Docker仓库..."
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg || true
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs 2>/dev/null || echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
        elif [[ "$ID" == "debian" ]]; then
            log_info "配置Debian Docker仓库..."
            curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg || true
            
            # Debian 13 (trixie) 在 Docker 官方可能还没完全独立稳定分支，降级使用 bookworm 分支进行安全兜底
            local docker_codename=$(lsb_release -cs 2>/dev/null || echo $VERSION_CODENAME)
            if [ "$docker_codename" = "trixie" ]; then
                docker_codename="bookworm"
                log_warn "检测到 Debian 13，自动降级采用成熟的 bookworm Docker 源以确保兼容"
            fi
            
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian ${docker_codename} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        else
            log_error "不支持的系统类型: $ID"
            return 0
        fi
        
        log_info "更新软件包列表..."
        sudo apt update -y || true
        
        log_info "安装Docker Engine..."
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --ignore-missing || log_error "Docker核心组件安装未完全成功"
        
        if [[ $EUID -ne 0 ]]; then
            sudo usermod -aG docker $USER || true
            log_info "已将用户 $USER 添加到docker组"
        fi
        
        # 启动服务
        sudo systemctl enable docker || true
        sudo systemctl start docker || true
        
        if command -v docker &> /dev/null; then
            log_info "Docker安装完成，版本: $(docker --version)"
        else
            log_error "Docker安装失败"
        fi
    fi
}

# 安装Docker Compose
install_docker_compose() {
    log_step "检查Docker Compose..."
    
    if docker compose version &> /dev/null; then
        log_info "Docker Compose Plugin已安装，版本: $(docker compose version)"
        return 0
    fi
    
    if command -v docker-compose &> /dev/null; then
        log_info "Docker Compose已安装，版本: $(docker-compose --version)"
        return 0
    fi
    
    log_info "安装Docker Compose独立版本..."
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
    
    if [[ -z "$DOCKER_COMPOSE_VERSION" ]]; then
        DOCKER_COMPOSE_VERSION="v2.24.0"
    fi
    
    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || true
    sudo chmod +x /usr/local/bin/docker-compose || true
}

# 设置上海时区
set_timezone() {
    log_step "设置时区为Asia/Shanghai..."
    sudo timedatectl set-timezone Asia/Shanghai || true
    log_info "当前时间: $(date)"
}

# 配置彩色命令行
setup_colorful_terminal() {
    log_step "配置彩色命令行..."
    
    if [[ -f ~/.bashrc ]]; then
        cp ~/.bashrc ~/.bashrc.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    if grep -q "force_color_prompt=yes" ~/.bashrc; then
        log_info "彩色提示符已启用"
    else
        sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/' ~/.bashrc 2>/dev/null || true
    fi
    
    if grep -q "自定义彩色配置 (由init.sh添加)" ~/.bashrc; then
        log_info "自定义彩色配置已存在"
    else
        cat >> ~/.bashrc << 'EOF'

# === 自定义彩色配置 (由init.sh添加) ===
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias lh='ls -lah --color=auto'
alias lt='ls -ltr --color=auto'

alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias c='clear'
alias path='echo -e ${PATH//:/\\n}'

# Docker别名
alias dps='docker ps'
alias dpsa='docker ps -a'
alias di='docker images'
alias dc='docker compose'
alias dcup='docker compose up -d'
alias dcdown='docker compose down'
alias dclogs='docker compose logs -f'
EOF
        log_info "自定义彩色配置添加完成"
    fi
}

# 测试Docker
test_docker() {
    log_step "测试Docker安装..."
    if command -v docker &> /dev/null; then
        sudo docker run --rm hello-world &> /dev/null && log_info "Docker测试成功！" || log_warn "Docker测试未响应（可能由于外网拉取超时），请稍后手动测试"
    fi
}

# 显示完成信息
show_completion() {
    echo
    log_info "======================================"
    log_info "系统初始化处理程序运行完毕！"
    log_info "======================================"
    echo
    log_warn "请运行以下命令使终端配置生效: source ~/.bashrc"
    echo
}

# 主函数
main() {
    log_info "开始Linux系统初始化..."
    check_root
    detect_system
    
    if [[ "$ID" == "debian" ]]; then
        fix_debian_sources
    fi
    
    update_system
    install_packages
    install_docker
    install_docker_compose
    set_timezone
    setup_colorful_terminal
    test_docker
    show_completion
}

main "$@"
