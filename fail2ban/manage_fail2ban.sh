#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限或 sudo 运行此脚本！"
  exit 1
fi

# 定义颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 状态检查函数
check_status() {
    if command -v fail2ban-client &> /dev/null; then
        echo -e "Fail2ban 状态: ${GREEN}已安装${NC}"
        if systemctl is-active --quiet fail2ban; then
            echo -e "服务运行状态: ${GREEN}正在运行 (Running)${NC}"
        else
            echo -e "服务运行状态: ${RED}已停止 (Stopped)${NC}"
        fi
    else
        echo -e "Fail2ban 状态: ${RED}未安装${NC}"
    fi
}

# 1. 安装与配置
install_f2b() {
    echo -e "${YELLOW}[1/4] 开始检测系统环境并安装...${NC}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install fail2ban -y
    elif [ -f /etc/redhat-release ]; then
        if command -v dnf &> /dev/null; then
            dnf install epel-release -y && dnf install fail2ban -y
        else
            yum install epel-release -y && yum install fail2ban -y
        fi
    else
        echo -e "${RED}未知的操作系统类型，请手动安装。${NC}"
        return 1
    fi

    echo -e "${YELLOW}[2/4] 正在写入优化后的 /etc/fail2ban/jail.local 配置...${NC}"
    [ -f /etc/fail2ban/jail.local ] && mv /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak

    # 默认配置：5分钟内错3次，封禁1小时
    cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = 1h
findtime = 5m
maxretry = 3
banaction = iptables-multiport

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

    echo -e "${YELLOW}[3/4] 启动服务并设置自启...${NC}"
    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl restart fail2ban

    echo -e "${YELLOW}[4/4] 正在验证运行状态...${NC}"
    sleep 2
    fail2ban-client status
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}Fail2ban 安装与初始配置成功！${NC}"
    echo -e "${GREEN}==========================================${NC}"
}

# 2. 卸载 Fail2ban
uninstall_f2b() {
    echo -e "${RED}警告：您正在准备彻底卸载 Fail2ban！${NC}"
    read -p "确定要继续吗？(y/n): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo -e "${YELLOW}正在停止并清理 Fail2ban 服务...${NC}"
        systemctl stop fail2ban
        systemctl disable fail2ban

        if [ -f /etc/debian_version ]; then
            apt-get purge fail2ban -y
            apt-get autoremove -y
        elif [ -f /etc/redhat-release ]; then
            if command -v dnf &> /dev/null; then
                dnf remove fail2ban -y
            else
                yum remove fail2ban -y
            fi
        fi
        # 清理残余配置
        rm -rf /etc/fail2ban
        echo -e "${GREEN}Fail2ban 已经成功从系统彻底卸载！${NC}"
    else
        echo "已取消卸载。"
    fi
}

# 3. 放行（解封）IP
unban_ip() {
    read -p "请输入需要放行（解封）的 IP 地址: " ip
    if [ -z "$ip" ]; then
        echo -e "${RED}IP 不能为空！${NC}"
        return 1
    fi
    # 默认尝试从 sshd 监狱中解封
    fail2ban-client set sshd unbanip "$ip"
}

# 4. 手动封禁 IP
ban_ip() {
    read -p "请输入需要手动封禁的 IP 地址: " ip
    if [ -z "$ip" ]; then
        echo -e "${RED}IP 不能为空！${NC}"
        return 1
    fi
    fail2ban-client set sshd banip "$ip"
}

# 5. 查看实时封禁列表
view_status() {
    echo -e "${YELLOW}--- 当前正在防护的 Jail 列表 ---${NC}"
    fail2ban-client status
    echo ""
    echo -e "${YELLOW}--- SSHD 监狱详细封禁名单 ---${NC}"
    fail2ban-client status sshd
}

# 交互主菜单
while true; do
    echo ""
    echo -e "${GREEN}==========================================${NC}"
    echo -e "       Fail2ban 运维多功能管理脚本        "
    echo -e "${GREEN}==========================================${NC}"
    check_status
    echo "------------------------------------------"
    echo " 1. 一键安装 / 重置配置 Fail2ban"
    echo " 2. 一键彻底卸载 Fail2ban"
    echo " 3. 手动放行（解封）某个 IP"
    echo " 4. 手动强行封禁某个 IP"
    echo " 5. 查看当前封禁名单与统计"
    echo " 6. 退出脚本"
    echo "------------------------------------------"
    read -p "请选择操作序号 [1-6]: " choice
    echo ""

    case $choice in
        1) install_f2b ;;
        2) uninstall_f2b ;;
        3) unban_ip ;;
        4) ban_ip ;;
        5) view_status ;;
        6) echo "退出脚本，祝你今天过得愉快！"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择信息信息。${NC}" ;;
    esac
done