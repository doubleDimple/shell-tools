#!/bin/bash

# Linux系统初始化脚本 - 支持Ubuntu和Debian
# 作者: doubleDimple
# 功能: 修复源配置、安装必要组件、设置上海时区、配置彩色命令行、安装Docker

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
        
        # 获取版本代号
        VERSION_CODENAME=$(lsb_release -cs)
        log_info "检测到Debian版本: $VERSION_CODENAME"
        
        # 配置正确的sources.list
        log_info "配置Debian官方镜像源..."
        sudo tee /etc/apt/sources.list > /dev/null <<EOF
# Debian $VERSION_CODENAME repositories
deb http://deb.debian.org/debian $VERSION_CODENAME main contrib non-free
deb-src http://deb.debian.org/debian $VERSION_CODENAME main contrib non-free

# Debian $VERSION_CODENAME updates
deb http://deb.debian.org/debian $VERSION_CODENAME-updates main contrib non-free
deb-src http://deb.debian.org/debian $VERSION_CODENAME-updates main contrib non-free

# Debian $VERSION_CODENAME security updates (修复格式)
deb http://security.debian.org/debian-security $VERSION_CODENAME-security main contrib non-free
deb-src http://security.debian.org/debian-security $VERSION_CODENAME-security main contrib non-free
EOF
        
        log_info "已修复Debian源配置"
        
        # 清理并更新
        sudo apt clean
        sudo apt update -y
        log_info "软件源更新完成"
    fi
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

# 安装Docker
install_docker() {
    log_step "检查并安装Docker..."
    
    if command -v docker &> /dev/null; then
        log_info "Docker已安装，版本: $(docker --version)"
    else
        log_info "安装Docker..."
        
        # 确保源配置正确后再安装Docker
        log_info "准备Docker安装环境..."
        sudo apt update -y
        
        # 安装必要的依赖
        sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
        
        # 根据系统类型设置正确的仓库
        if [[ "$ID" == "ubuntu" ]]; then
            # Ubuntu系统
            log_info "配置Ubuntu Docker仓库..."
            
            # 添加Docker官方GPG密钥
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            
            # 添加Docker仓库
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
        elif [[ "$ID" == "debian" ]]; then
            # Debian系统
            log_info "配置Debian Docker仓库..."
            
            # 添加Docker官方GPG密钥
            curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            
            # 添加Docker仓库
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
        else
            log_error "不支持的系统类型: $ID"
            return 1
        fi
        
        # 更新包索引
        sudo apt update -y
        
        # 安装Docker
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
        
        log_info "Docker安装完成"
    fi
}

# 安装Docker Compose
install_docker_compose() {
    log_step "检查并安装Docker Compose..."
    
    if command -v docker-compose &> /dev/null; then
        log_info "Docker Compose已安装，版本: $(docker-compose --version)"
    else
        log_info "安装Docker Compose..."
        # 下载最新版本的Docker Compose
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        
        # 添加执行权限
        sudo chmod +x /usr/local/bin/docker-compose
        
        # 验证安装
        if command -v docker-compose &> /dev/null; then
            log_info "Docker Compose安装完成，版本: $(docker-compose --version)"
        else
            log_error "Docker Compose安装失败"
            return 1
        fi
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
alias dc='docker-compose'
alias dcup='docker-compose up -d'
alias dcdown='docker-compose down'
alias dclogs='docker-compose logs -f'
alias dcps='docker-compose ps'

EOF
    
    log_info "彩色命令行配置完成"
}

# 显示完成信息
show_completion() {
    echo
    log_info "======================================"
    log_info "系统初始化完成！"
    log_info "======================================"
    echo
    log_info "已完成的配置:"
    echo "  ✓ Debian软件源修复"
    echo "  ✓ 系统软件包更新"
    echo "  ✓ 必要组件安装"
    echo "  ✓ Docker安装"
    echo "  ✓ Docker Compose安装"
    echo "  ✓ 时区设置为Asia/Shanghai"
    echo "  ✓ 彩色命令行配置"
    echo
    log_warn "请运行以下命令使配置生效:"
    echo "  source ~/.bashrc"
    if [[ $EUID -ne 0 ]] && command -v docker &> /dev/null; then
        echo "  newgrp docker  # 或重新登录以使docker组权限生效"
    fi
    echo
    log_warn "或者重新登录系统"
    echo
    log_info "Docker信息:"
    if command -v docker &> /dev/null; then
        docker --version
    fi
    if command -v docker-compose &> /dev/null; then
        docker-compose --version
    fi
    echo
    log_info "时间信息:"
    timedatectl
}

# 主函数
main() {
    log_info "开始Linux系统初始化..."
    echo
    
    check_root
    detect_system
    
    echo
    log_info "将自动执行以下操作:"
    echo "  • 修复Debian软件源配置"
    echo "  • 系统软件包更新"
    echo "  • 必要组件安装"
    echo "  • Docker安装"
    echo "  • Docker Compose安装"
    echo "  • 时区设置为Asia/Shanghai"
    echo "  • 彩色命令行配置"
    echo
    
    fix_debian_sources
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
    show_completion
}

# 执行主函数
main "$@"
