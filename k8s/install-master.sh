#!/bin/bash
# Kubernetes + Dashboard 简化安装脚本 - 支持 Ubuntu/Debian/CentOS/RHEL
set -e

echo "🚀 Kubernetes + Dashboard 简化安装脚本 v1.0"
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

# 清理旧的 Kubernetes 安装
cleanup_old_k8s() {
    echo ""
    echo "🧹 [1/10] 清理旧的 Kubernetes 组件..."
    
    # 停止服务
    systemctl stop kubelet 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
    
    # 重置 kubeadm
    kubeadm reset -f 2>/dev/null || true
    
    # 卸载软件包
    case $PKG_MANAGER in
        apt)
            apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
            apt remove --purge -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
            apt remove --purge -y containerd.io containerd 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
            ;;
        yum|dnf)
            $PKG_MANAGER remove -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
            $PKG_MANAGER remove -y containerd.io containerd 2>/dev/null || true
            $PKG_MANAGER autoremove -y 2>/dev/null || true
            ;;
    esac
    
    # 清理文件和目录
    rm -rf ~/.kube
    rm -rf /etc/kubernetes
    rm -rf /var/lib/kubelet
    rm -rf /var/lib/etcd
    rm -rf /etc/containerd
    rm -rf /var/lib/containerd
    rm -rf /opt/cni
    rm -rf /etc/cni
    rm -rf /var/lib/cni
    rm -rf /run/flannel
    rm -rf /etc/systemd/system/kubelet.service.d
    
    # 清理网络接口
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    
    # 清理 iptables 规则
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    
    systemctl daemon-reload
    
    echo "✅ 清理完成"
}

# 更新系统
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

# 安装基础包
install_basic_packages() {
    case $PKG_MANAGER in
        apt)
            apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common wget
            ;;
        yum|dnf)
            $PKG_MANAGER install -y curl gnupg2 software-properties-common yum-utils device-mapper-persistent-data lvm2 wget
            ;;
    esac
}

# 安装 containerd
install_containerd() {
    case $OS in
        ubuntu)
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt update
            apt install -y containerd.io
            ;;
        debian)
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt update
            apt install -y containerd.io
            ;;
        centos|rhel|rocky|almalinux)
            $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            $PKG_MANAGER install -y containerd.io
            ;;
    esac
}

# 安装 Kubernetes
install_kubernetes() {
    case $PKG_MANAGER in
        apt)
            curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
            echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
            apt update
            apt install -y kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1
            apt-mark hold kubelet kubeadm kubectl
            ;;
        yum|dnf)
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

# 清理旧安装
cleanup_old_k8s

echo ""
echo "📦 [2/10] 更新系统并安装依赖..."
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
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i '/disabled_plugins.*cri/d' /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

echo ""
echo "☸️  [6/10] 安装 Kubernetes 1.29..."
install_kubernetes

systemctl enable kubelet

echo ""
echo "🔧 [7/10] 配置 CRI 接口..."
cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
EOF

echo ""
echo "🎯 [8/10] 初始化 Kubernetes 集群..."

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

# 移除 master 污点（允许在 master 节点运行 Pod）
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo ""
echo "🌐 [9/10] 安装 Flannel 网络插件..."

# 安装 Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 等待网络插件就绪
echo "等待网络插件就绪..."
sleep 30

echo ""
echo "📊 [10/10] 安装 Kubernetes Dashboard..."

# 安装 Dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

# 修改服务类型为 NodePort
kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8443,"nodePort":30443}]}}'

# 创建管理员用户
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-user-token
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/service-account-token
EOF

# 等待 Dashboard 启动
echo "等待 Dashboard 启动..."
kubectl wait --for=condition=available --timeout=300s deployment/kubernetes-dashboard -n kubernetes-dashboard || true

# 获取访问令牌
sleep 5
K8S_TOKEN=$(kubectl get secret admin-user-token -n kubernetes-dashboard -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || echo "Token生成失败")

echo ""
echo "=========================================="
echo "🎉 Kubernetes 集群安装完成！"
echo "=========================================="
echo ""
echo "📊 集群状态："
kubectl get nodes -o wide
echo ""
kubectl get pods --all-namespaces

echo ""
echo "=========================================="
echo "🔑 访问信息"
echo "=========================================="
echo ""
echo "📍 Kubernetes Dashboard 地址:"
echo "   https://$LOCAL_IP:30443"
echo ""
echo "🔐 登录令牌:"
echo "   $K8S_TOKEN"
echo ""
echo "=========================================="
echo "💡 常用命令"
echo "=========================================="
echo ""
echo "查看所有 Pod:"
echo "  kubectl get pods --all-namespaces"
echo ""
echo "查看节点状态:"
echo "  kubectl get nodes"
echo ""
echo "查看 Dashboard 服务:"
echo "  kubectl get svc -n kubernetes-dashboard"
echo ""
echo "重新生成访问令牌:"
echo "  kubectl -n kubernetes-dashboard create token admin-user"
echo ""
echo "查看集群信息:"
echo "  kubectl cluster-info"
echo ""
echo "=========================================="
echo "⚠️  注意事项"
echo "=========================================="
echo ""
echo "1. 使用 HTTPS 访问 Dashboard，浏览器会提示证书警告"
echo "   点击'高级' -> '继续访问'即可"
echo ""
echo "2. 如果是云服务器，请确保防火墙开放端口:"
echo "   - 6443 (Kubernetes API)"
echo "   - 30443 (Dashboard)"
echo ""
echo "3. Worker 节点加入命令:"
kubeadm token create --print-join-command
echo ""
echo "=========================================="
echo "✅ 安装完成！"
