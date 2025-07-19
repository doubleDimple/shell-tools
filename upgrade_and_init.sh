#!/bin/bash

set -e

echo "📦 第一步：更新 Debian 10 软件..."
apt update
apt upgrade -y
apt full-upgrade -y
apt --purge autoremove -y

echo "🔧 第二步：替换为 Debian 11 (bullseye) 源..."
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
EOF

echo "🔄 第三步：执行 Debian 11 升级..."
apt update
apt upgrade --without-new-pkgs -y
apt full-upgrade -y
apt update

echo "🧰 安装必要工具（lsb-release, sudo, wget, curl）..."
apt install -y lsb-release sudo wget curl

echo "🚀 下载并执行 init.sh 脚本..."
wget -O init.sh https://raw.githubusercontent.com/doubleDimple/shell-tools/master/init.sh
chmod +x init.sh
./init.sh

echo "✅ 所有步骤已完成，系统将在 30 秒后重启..."
sleep 30
reboot
