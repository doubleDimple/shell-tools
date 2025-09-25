# 🐧 Linux 初始化脚本

> 一键式 Linux 系统初始化和配置脚本

## 📦 init.sh - 系统初始化脚本

### 使用方法

**第一步：下载脚本**
```bash
wget -O init.sh https://raw.githubusercontent.com/doubleDimple/shell-tools/master/init.sh && chmod +x init.sh
```

**第二步：运行脚本**
```bash
./init.sh
```

## 🚨 Debian 10 应急安装

> 适用于新系统无法安装任何命令的情况

```bash
bash << 'EOF'
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
apt upgrade -y && apt full-upgrade -y && apt --purge autoremove -y && \
echo 'deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free' > /etc/apt/sources.list && \
apt update && apt upgrade --without-new-pkgs -y && apt full-upgrade -y && apt update && \
apt install lsb-release sudo wget curl -y && \
wget -O upgrade_and_init.sh https://raw.githubusercontent.com/doubleDimple/shell-tools/master/upgrade_and_init.sh && \
chmod +x upgrade_and_init.sh && \
./upgrade_and_init.sh
EOF
```

## ⚡ setUp-eth.sh - 以太坊配置脚本

**下载脚本**
```bash
wget -O setUp-eth.sh https://raw.githubusercontent.com/doubleDimple/shell-tools/master/setUp-eth.sh && chmod +x setUp-eth.sh
```

**运行脚本**
```bash
./setUp-eth.sh
```
