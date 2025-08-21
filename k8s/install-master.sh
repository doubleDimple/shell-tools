#!/bin/bash
# Kubernetes 完整安装脚本 - 彻底重新安装
set -e

echo "🚀 开始完整重新安装 Kubernetes 集群..."

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "❌ 此脚本需要 root 权限运行"
   echo "请使用: sudo $0"
   exit 1
fi

echo "🧹 [1/9] 彻底卸载之前的安装..."

# 停止所有相关服务
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true
systemctl stop docker 2>/dev/null || true

# 重置 kubeadm 配置
kubeadm reset -f 2>/dev/null || true

# 卸载 Kubernetes 组件
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt remove --purge -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true

# 卸载容器运行时
apt remove --purge -y docker-ce docker-ce-cli containerd.io containerd docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
apt autoremove -y

# 清理配置文件和目录
rm -rf ~/.kube
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /etc/docker
rm -rf /etc/containerd
rm -rf /var/lib/containerd
rm -rf /opt/containerd
rm -rf /etc/systemd/system/kubelet.service.d
rm -rf /etc/apt/sources.list.d/kubernetes.list
rm -rf /etc/apt/sources.list.d/docker.list
rm -rf /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -rf /etc/apt/keyrings/docker.gpg

# 清理网络配置
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true

echo "📦 [2/9] 更新系统并安装基础依赖..."
apt update
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common

echo "🔧 [3/9] 配置内核参数..."
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

echo "🐳 [4/9] 安装 containerd..."
# 添加 Docker 官方仓库
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 安装 containerd
apt update
apt install -y containerd.io

# 创建 containerd 配置
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# 配置 containerd 使用 systemd cgroup 驱动
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# 启动 containerd
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

# 等待 containerd 启动
sleep 5

echo "☸️  [5/9] 安装 Kubernetes 组件..."
# 添加 Kubernetes 仓库
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

# 更新软件包列表并安装 Kubernetes 组件
apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 启动 kubelet
systemctl enable kubelet

echo "🔧 [6/9] 配置容器运行时接口..."
# 配置 crictl
cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo "🔍 [7/9] 验证安装状态..."
echo "Containerd 状态:"
systemctl status containerd --no-pager -l

echo "测试 CRI 接口:"
crictl version

echo "Kubernetes 版本:"
kubeadm version

echo "🎯 [8/9] 初始化 Kubernetes 集群..."
# 获取本机 IP
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo "使用 IP 地址: $LOCAL_IP"

# 初始化集群
kubeadm init \
    --apiserver-advertise-address=$LOCAL_IP \
    --pod-network-cidr=10.244.0.0/16 \
    --service-cidr=10.96.0.0/12 \
    --cri-socket=unix:///var/run/containerd/containerd.sock

# 配置 kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 移除 master 节点的污点（单节点集群）
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

echo "🌐 [9/9] 安装网络插件和应用..."
# 安装 Flannel 网络插件
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 等待节点就绪
echo "⏳ 等待节点就绪（最多5分钟）..."
kubectl wait --for=condition=Ready node --all --timeout=300s

# 安装 KubeSphere (可选)
echo "📊 安装 KubeSphere 控制台..."
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml

echo ""
echo "🎉 Kubernetes 集群安装完成！"
echo "================================================================"
echo ""

# 显示集群信息
echo "📋 集群状态:"
kubectl get nodes -o wide
echo ""

echo "🔍 Pod 状态:"
kubectl get pods --all-namespaces
echo ""

echo "🔑 Worker 节点加入命令："
echo "================================================================"
kubeadm token create --print-join-command
echo "================================================================"
echo ""

echo "📊 KubeSphere 控制台信息："
echo "地址: http://$LOCAL_IP:30880"
echo "默认用户: admin"
echo "默认密码: P@88w0rd"
echo ""

echo "🔍 查看 KubeSphere 安装进度："
echo "kubectl logs -n kubesphere-system deployment/ks-installer -f"
echo ""

echo "⚠️  重要提醒："
echo "1. KubeSphere 完全启动需要 5-10 分钟，请耐心等待"
echo "2. 如果是云服务器，请确保防火墙开放以下端口："
echo "   - 6443 (Kubernetes API)"
echo "   - 30000-32767 (NodePort 服务)"
echo "   - 30880 (KubeSphere 控制台)"
echo "3. 首次登录 KubeSphere 后请及时修改默认密码"
echo ""

echo "🔧 常用管理命令："
echo "kubectl get nodes                    # 查看节点状态"
echo "kubectl get pods --all-namespaces   # 查看所有 Pod"
echo "kubectl get svc --all-namespaces    # 查看所有服务"
echo "kubectl cluster-info                # 查看集群信息"
echo "systemctl status kubelet            # 查看 kubelet 状态"
echo "systemctl status containerd         # 查看 containerd 状态"
echo ""

echo "✅ 安装脚本执行完毕！"
