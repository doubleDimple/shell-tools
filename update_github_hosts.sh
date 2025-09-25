#!/bin/bash
# 自动更新 GitHub Hosts
# Author: convoy le (for internal use)
# 1:chmod +x update_github_hosts.sh
# 2:sudo ./update_github_hosts.sh
# 3:systemctl restart nscd 2>/dev/null || systemctl restart systemd-resolved 2>/dev/null
# --------------------------------------

HOSTS_FILE="/etc/hosts"
BACKUP_FILE="/etc/hosts.bak.$(date +%F-%H%M%S)"

# GitHub 常用域名
DOMAINS=(
    "github.com"
    "assets-cdn.github.com"
    "github.global.ssl.fastly.net"
    "raw.githubusercontent.com"
    "user-images.githubusercontent.com"
    "avatars.githubusercontent.com"
    "avatars0.githubusercontent.com"
    "avatars1.githubusercontent.com"
    "avatars2.githubusercontent.com"
    "avatars3.githubusercontent.com"
    "avatars4.githubusercontent.com"
    "avatars5.githubusercontent.com"
    "codeload.github.com"
)

echo "[INFO] 备份原始 hosts -> $BACKUP_FILE"
cp $HOSTS_FILE $BACKUP_FILE

# 用于测速的函数
function get_fast_ip() {
    local domain=$1
    local best_ip=""
    local best_ping=999999

    # 使用多个公共DNS解析
    for dns in 223.5.5.5 119.29.29.29 8.8.8.8 1.1.1.1; do
        ip=$(dig @$dns +short $domain | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
        if [ -n "$ip" ]; then
            ping_ms=$(ping -c 1 -W 1 $ip 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}')
            ping_ms=${ping_ms%.*}
            if [ -n "$ping_ms" ] && [ "$ping_ms" -lt "$best_ping" ]; then
                best_ping=$ping_ms
                best_ip=$ip
            fi
        fi
    done

    echo $best_ip
}

# 更新 hosts 文件
echo "[INFO] 正在更新 $HOSTS_FILE ..."
for domain in "${DOMAINS[@]}"; do
    ip=$(get_fast_ip $domain)
    if [ -n "$ip" ]; then
        echo "[OK] $domain -> $ip"
        # 删除原有条目
        sed -i "/$domain/d" $HOSTS_FILE
        echo "$ip $domain" >> $HOSTS_FILE
    else
        echo "[WARN] $domain 无法解析"
    fi
done

echo "[DONE] GitHub hosts 已更新，请尝试访问 github.com"
