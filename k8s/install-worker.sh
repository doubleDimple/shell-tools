#!/bin/bash
# Kubernetes Worker 节点安装脚本 - 兼容 Master 节点版本
set -e

echo "🚀 Kubernetes Worker 节点安装脚本 v1.0"
echo "兼容 Kubernetes 1.29 版本"

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
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        echo "❌ 无法检测系统类型"
        exit 1
    fi
    
    echo "检测到系统: $OS"
    
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
}

detect_os

echo ""
echo "[1/7] 更新系统并安装基础依赖..."
if [ "$PKG_MANAGER" = "apt" ]; then
    apt update
    apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common wget socat conntrack ebtables ipset
elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
    $PKG_MANAGER install -y curl wget socat conntrack ebtables ipset yum-utils device-mapper-persistent-data lvm2 gnupg2
fi

echo ""
echo "[2/7] 配置内核参数..."
# 加载必要的内核模块
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

echo ""
echo "[3/7] 禁用 swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 禁用 SELinux (对于 RHEL/CentOS)
if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "rocky" ] || [ "$OS" = "almalinux" ]; then
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
fi

echo ""
echo "[4/7] 安装 Containerd..."
if [ "$PKG_MANAGER" = "apt" ]; then
    # 添加 Docker 仓库（containerd 来自这里）
    mkdir -p /etc/apt/keyrings
    if [ "$OS" = "ubuntu" ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    else
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi
    apt update
    apt install -y containerd.io
elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
    # 添加 Docker 仓库
    $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    $PKG_MANAGER install -y containerd.io
fi

echo ""
echo "[5/7] 配置 Containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# 配置 systemd cgroup 驱动（重要！必须与 Master 节点一致）
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 确保 CRI 插件未被禁用
sed -i '/disabled_plugins.*cri/d' /etc/containerd/config.toml

# 重启并启用 containerd
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

# 等待 containerd 启动
sleep 5

echo ""
echo "[6/7] 配置 CRI 工具..."
# 安装 cri-tools
if [ "$PKG_MANAGER" = "apt" ]; then
    apt install -y cri-tools
elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
    $PKG_MANAGER install -y cri-tools
fi

# 配置 crictl
cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
EOF

echo ""
echo "[7/7] 安装 Kubernetes 组件 (v1.29.0，与 Master 一致)..."
if [ "$PKG_MANAGER" = "apt" ]; then
    # 使用新的 Kubernetes 仓库（与 Master 节点保持一致）
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
    apt update
    # 安装特定版本，与 Master 节点一致
    apt install -y kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1
    apt-mark hold kubelet kubeadm kubectl
elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
    # 使用新的 Kubernetes 仓库
    cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF
    # 安装特定版本
    $PKG_MANAGER install -y kubelet-1.29.0 kubeadm-1.29.0 kubectl-1.29.0 --disableexcludes=kubernetes
fi

# 启用 kubelet 服务
systemctl enable kubelet

echo ""
echo "=========================================="
echo "✅ Worker 节点准备完成！"
echo "=========================================="
echo ""
echo "📋 已安装组件版本："
echo "Containerd: $(containerd --version)"
echo "Kubeadm: $(kubeadm version -o short)"
echo "Kubelet: $(kubelet --version)"
echo "Kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
echo ""
echo "=========================================="
echo "📌 下一步操作："
echo "=========================================="
echo ""
echo "1. 在 Master 节点上执行以下命令生成加入令牌："
echo "   kubeadm token create --print-join-command"
echo ""
echo "2. 复制生成的命令到本节点执行，命令格式类似："
echo "   kubeadm join <master-ip>:6443 --token <token> \\"
echo "     --discovery-token-ca-cert-hash sha256:<hash>"
echo ""
echo "3. 加入成功后，在 Master 节点验证："
echo "   kubectl get nodes"
echo ""
echo "=========================================="
echo "⚠️  注意事项："
echo "=========================================="
echo ""
echo "1. 确保本节点能够访问 Master 节点的 6443 端口"
echo "2. 如果加入失败，可以执行 'kubeadm reset' 后重试"
echo "3. 加入集群后需要等待片刻才能在 Master 看到 Ready 状态"
echo ""
echo "=========================================="
echo "💡 故障排查命令："
echo "=========================================="
echo ""
echo "查看 kubelet 日志："
echo "  journalctl -xeu kubelet -f"
echo ""
echo "查看 containerd 状态："
echo "  systemctl status containerd"
echo ""
echo "测试 containerd："
echo "  crictl version"
echo "  crictl info"
echo ""
echo "==========================================
