init.sh lunux初始化脚本
第一步:下载脚本
wget -O init.sh https://raw.githubusercontent.com/doubleDimple/shell-tools/master/init.sh && chmod +x init.sh
第二步:运行脚本
./init.sh


debain10的新系统,无法安装任何命令使用如下脚本直接复制-回车执行
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


setup,sh使用流程
wget -O setUp-eth.sh https://raw.githubusercontent.com/doubleDimple/shell-tools/master/setUp-eth.sh && chmod +x setUp-eth.sh
运行:
./setUp-eth.sh
