#!/bin/bash
# 修复后的 Kubernetes 安装脚本 - 使用 containerd 作为容器运行时
set -e

echo "🚀 开始安装 Kubernetes 集群..."

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "❌ 此脚本需要 root 权限运行"
   exit 1
fi

# 清理之前的安装
echo "🧹 [1/8] 清理之前的配置..."
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true
systemctl stop docker 2>/dev/null || true
kubeadm reset -f 2>/dev/null || true

# 移除旧的容器运行时
apt remove --purge -y docker-ce docker-ce-cli containerd.io containerd 2>/dev/null || true
rm -rf /etc/docker /etc/containerd

echo "📦 [2/8] 安装系统依赖..."
# 更新系统并安装必要的软件包
apt update
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common

echo "🔧 [3/8] 配置内核参数..."
# 加载必要的内核模块
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 设置系统参数
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "🐳 [4/8] 安装 containerd..."
# 安装 containerd
apt update
apt install -y containerd

# 创建 containerd 配置目录
mkdir -p /etc/containerd

# 生成默认配置
containerd config default | tee /etc/containerd/config.toml

# 配置 containerd 使用 systemd cgroup 驱动
sed -i 's/SystemdCgroup \= false/SystemdCgroup = true/g' /etc/containerd/config.toml

# 启动 containerd
systemctl daemon-reload
systemctl enable containerd
systemctl start containerd

echo "☸️  [5/8] 安装 Kubernetes 组件..."
# 添加 Kubernetes 仓库
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

# 安装 kubelet、kubeadm 和 kubectl
apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 启动 kubelet
systemctl enable kubelet

echo "🔍 [6/8] 验证容器运行时状态..."
systemctl status containerd --no-pager -l
ctr version

echo "🎯 [7/8] 初始化 Kubernetes 集群..."
# 获取本机 IP
LOCAL_IP=$(hostname -I | awk '{print $1}')

# 初始化集群
kubeadm init \
    --apiserver-advertise-address=$LOCAL_IP \
    --pod-network-cidr=10.244.0.0/16 \
    --service-cidr=10.96.0.0/12 \
    --kubernetes-version=v1.28.0

# 配置 kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 允许在 master 节点调度 pod（单节点集群）
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

echo "🌐 [8/8] 安装网络插件和 KubeSphere..."
# 安装 Flannel 网络插件
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 等待节点就绪
echo "⏳ 等待节点就绪..."
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "📊 安装 KubeSphere..."
# 安装 KubeSphere 前置条件
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml

# 下载并应用 KubeSphere 配置
curl -L -O https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml
kubectl apply -f cluster-configuration.yaml

echo ""
echo "🎉 Kubernetes 集群安装完成！"
echo ""
echo "📋 集群信息："
echo "================================================================"
kubectl get nodes -o wide
echo "================================================================"
echo ""
echo "🔑 Worker 节点加入命令："
echo "================================================================"
kubeadm token create --print-join-command
echo "================================================================"
echo ""
echo "📊 KubeSphere 控制台："
echo "地址: http://$LOCAL_IP:30880"
echo "默认用户: admin"  
echo "默认密码: P@88w0rd"
echo ""
echo "🔍 查看 KubeSphere 安装进度："
echo "kubectl logs -n kubesphere-system deployment/ks-installer -f"
echo ""
echo "⚠️  注意事项："
echo "1. KubeSphere 完全启动需要 5-10 分钟，请耐心等待"
echo "2. 如果是云服务器，请确保安全组开放了 30880 端口"
echo "3. 首次登录后请及时修改默认密码"
echo ""
echo "🔧 常用命令："
echo "kubectl get pods --all-namespaces  # 查看所有 Pod"
echo "kubectl get svc --all-namespaces   # 查看所有服务"
echo "kubectl cluster-info               # 查看集群信息"
