#!/bin/bash
# Kubernetes 完整安装脚本 - 支持 Ubuntu/Debian/CentOS/RHEL
set -e

echo "🚀 Kubernetes 多系统兼容安装脚本 v3.0"
echo "支持 Ubuntu/Debian/CentOS/RHEL 系统"

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "❌ 此脚本需要 root 权限运行"
   echo "请使用: sudo $0"
   exit 1
fi

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        
        # 特别处理一些系统的识别
        case $ID in
            ubuntu)
                OS="ubuntu"
                CODENAME=$VERSION_CODENAME
                ;;
            debian)
                OS="debian" 
                CODENAME=$VERSION_CODENAME
                ;;
            centos|rhel|rocky|almalinux)
                OS=$ID
                ;;
            *)
                # 如果检测不到，通过文件判断
                if [ -f /etc/debian_version ]; then
                    if grep -q "ubuntu" /etc/os-release 2>/dev/null; then
                        OS="ubuntu"
                    else
                        OS="debian"
                    fi
                    CODENAME=$(lsb_release -cs 2>/dev/null || echo "bullseye")
                elif [ -f /etc/redhat-release ]; then
                    OS="centos"
                fi
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        CODENAME=$(lsb_release -cs 2>/dev/null || echo "bullseye")
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
    else
        echo "❌ 无法检测系统类型"
        exit 1
    fi
    
    echo "检测到系统: $OS"
    if [ -n "$OS_VERSION" ]; then
        echo "系统版本: $OS_VERSION"
    fi
    if [ -n "$CODENAME" ]; then
        echo "代码名: $CODENAME"
    fi
    
    # 设置包管理器
    case $OS in
        ubuntu|debian)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            fi
            ;;
        *)
            echo "❌ 不支持的系统: $OS"
            exit 1
            ;;
    esac
    
    echo "使用包管理器: $PKG_MANAGER"
}

# 更新系统函数
update_system() {
    case $PKG_MANAGER in
        apt)
            apt update
            ;;
        yum|dnf)
            $PKG_MANAGER update -y
            ;;
    esac
}

# 安装基础包函数
install_basic_packages() {
    case $PKG_MANAGER in
        apt)
            apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
            ;;
        yum|dnf)
            $PKG_MANAGER install -y curl gnupg2 software-properties-common yum-utils device-mapper-persistent-data lvm2
            ;;
    esac
}

# 安装 containerd 函数
install_containerd() {
    case $OS in
        ubuntu)
            # Ubuntu
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt update
            apt install -y containerd.io
            ;;
        debian)
            # Debian
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt update
            apt install -y containerd.io
            ;;
        centos|rhel|rocky|almalinux)
            # CentOS/RHEL
            $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            $PKG_MANAGER install -y containerd.io
            ;;
    esac
}

# 安装 Kubernetes 函数
install_kubernetes() {
    case $PKG_MANAGER in
        apt)
            # Ubuntu/Debian
            curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
            echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
            apt update
            apt install -y kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1
            apt-mark hold kubelet kubeadm kubectl
            ;;
        yum|dnf)
            # CentOS/RHEL
            cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF
            $PKG_MANAGER install -y kubelet-1.29.0 kubeadm-1.29.0 kubectl-1.29.0 --disableexcludes=kubernetes
            ;;
    esac
}

# 开始安装
detect_os

echo ""
echo "📋 系统信息："
echo "操作系统: $OS $OS_VERSION"
echo "包管理器: $PKG_MANAGER"
if [ -n "$CODENAME" ]; then
    echo "代码名: $CODENAME"
fi

echo ""
echo "🧹 [1/10] 彻底清理系统..."

# 停止所有服务
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true
systemctl stop docker 2>/dev/null || true

# 重置 kubeadm
kubeadm reset -f 2>/dev/null || true

# 彻底卸载所有相关软件包
case $PKG_MANAGER in
    apt)
        apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
        apt remove --purge -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
        apt remove --purge -y docker-ce docker-ce-cli containerd.io containerd 2>/dev/null || true
        apt remove --purge -y docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt autoremove -y
        apt autoclean
        ;;
    yum|dnf)
        $PKG_MANAGER remove -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
        $PKG_MANAGER remove -y docker-ce docker-ce-cli containerd.io containerd 2>/dev/null || true
        $PKG_MANAGER autoremove -y 2>/dev/null || true
        ;;
esac

# 清理残留文件
rm -rf ~/.kube /etc/kubernetes /var/lib/kubelet /var/lib/etcd
rm -rf /etc/docker /etc/containerd /var/lib/containerd /opt/containerd
rm -rf /etc/systemd/system/kubelet.service.d
rm -rf /etc/apt/sources.list.d/kubernetes*.list
rm -rf /etc/apt/sources.list.d/docker.list
rm -rf /etc/yum.repos.d/kubernetes.repo
rm -rf /etc/yum.repos.d/docker*.repo
rm -rf /etc/apt/keyrings/kubernetes*.gpg
rm -rf /etc/apt/keyrings/docker.gpg
rm -rf /etc/crictl.yaml

# 清理网络
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true

# 清理 iptables 规则
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true

echo "✅ 清理完成"

echo ""
echo "📦 [2/10] 安装系统依赖..."
update_system
install_basic_packages

echo ""
echo "🔧 [3/10] 配置内核参数..."
# 配置内核模块
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 配置系统参数
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# 禁用 SELinux (对于 RHEL/CentOS)
if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "rocky" ] || [ "$OS" = "almalinux" ]; then
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
fi

# 禁用 swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo ""
echo "🐳 [4/10] 安装 containerd..."
install_containerd

echo ""
echo "🔧 [5/10] 配置 containerd..."

# 停止 containerd 服务
systemctl stop containerd

# 创建配置目录
mkdir -p /etc/containerd

# 生成默认配置
containerd config default > /etc/containerd/config.toml

# 修改配置文件以启用 systemd cgroup 和 CRI
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 确保 CRI 插件未被禁用
sed -i '/disabled_plugins.*cri/d' /etc/containerd/config.toml

# 启动 containerd
systemctl daemon-reload
systemctl enable containerd
systemctl start containerd

# 等待服务启动
sleep 10

echo "验证 containerd 状态:"
systemctl status containerd --no-pager

echo ""
echo "☸️  [6/10] 安装 Kubernetes 1.29..."
install_kubernetes

# 启动 kubelet
systemctl enable kubelet

echo ""
echo "🔧 [7/10] 配置 CRI 接口..."

# 安装 cri-tools
case $PKG_MANAGER in
    apt)
        apt install -y cri-tools
        ;;
    yum|dnf)
        $PKG_MANAGER install -y cri-tools
        ;;
esac

# 配置 crictl
cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
EOF

echo ""
echo "🔍 [8/10] 验证安装..."

echo "containerd 版本:"
containerd --version

echo "crictl 版本:"
crictl version

echo "kubeadm 版本:"
kubeadm version

echo "kubelet 版本:"
kubelet --version

echo "kubectl 版本:"
kubectl version --client

# 测试 CRI 连接
echo "测试 CRI 连接:"
crictl info | head -20

echo ""
echo "🎯 [9/10] 初始化 Kubernetes 集群..."

# 获取本机 IP
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo "使用 IP 地址: $LOCAL_IP"

# 拉取必要的镜像
echo "预拉取 Kubernetes 镜像..."
kubeadm config images pull --cri-socket unix:///var/run/containerd/containerd.sock

# 初始化集群
echo "正在初始化集群..."
kubeadm init \
    --apiserver-advertise-address=$LOCAL_IP \
    --pod-network-cidr=10.244.0.0/16 \
    --service-cidr=10.96.0.0/12 \
    --cri-socket=unix:///var/run/containerd/containerd.sock \
    --kubernetes-version=v1.29.0

# 配置 kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 移除 master 污点
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo ""
echo "🌐 [10/10] 安装网络插件..."

# 安装 Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 等待节点就绪
echo "等待节点就绪..."
kubectl wait --for=condition=Ready node --all --timeout=300s || true

# 安装 KubeSphere
echo "安装 KubeSphere..."
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml

echo ""
echo "🎉 安装完成！"
echo "================================================================"

# 显示集群状态
echo "集群节点状态:"
kubectl get nodes -o wide

echo ""
echo "系统 Pods 状态:"
kubectl get pods -n kube-system

echo ""
echo "================================================================"
echo "🔑 Worker 节点加入命令："
kubeadm token create --print-join-command
echo "================================================================"

echo ""
echo "📊 KubeSphere 控制台："
echo "地址: http://$LOCAL_IP:30880"
echo "用户: admin"
echo "密码: P@88w0rd"

echo ""
echo "🔍 监控命令："
echo "kubectl get pods --all-namespaces               # 查看所有 Pod"
echo "kubectl logs -n kubesphere-system deployment/ks-installer -f  # KubeSphere 安装日志"
echo "systemctl status kubelet                        # kubelet 状态"
echo "systemctl status containerd                     # containerd 状态"
echo "crictl ps                                       # 容器列表"

echo ""
echo "⚠️  注意："
echo "1. KubeSphere 完全启动需要 5-10 分钟"
echo "2. 如果是云服务器，请开放 6443 和 30880 端口"
echo "3. 建议首次登录后修改默认密码"

echo ""
echo "✅ 脚本执行完毕！请等待所有 Pod 启动完成。"
