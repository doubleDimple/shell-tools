#!/bin/bash
# 清理旧配置并重新安装 Kubernetes Master 节点
set -e

echo "🧹 [0/6] 清理旧的 Kubernetes 仓库配置..."

# 删除旧的 Kubernetes 仓库文件
if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
    echo "删除旧的 kubernetes.list..."
    rm -f /etc/apt/sources.list.d/kubernetes.list
fi

# 清理旧的 GPG 密钥
if command -v apt-key >/dev/null 2>&1; then
    echo "清理旧的 GPG 密钥..."
    apt-key del 7F92E05B31093BEF5A3C2D38FEEA9169307EA071 >/dev/null 2>&1 || true
    apt-key del 54A647F9048D5688D7DA2ABE6A030B21BA07F4FB >/dev/null 2>&1 || true
fi

# 创建 keyrings 目录
mkdir -p /etc/apt/keyrings

# 更新包列表
apt update

echo "[1/6] 更新系统并安装依赖..."
apt update -y
apt install -y curl wget socat conntrack ebtables ipset apt-transport-https ca-certificates gnupg lsb-release

echo "[2/6] 关闭 swap & 配置内核参数..."
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 加载必需的内核模块
modprobe overlay
modprobe br_netfilter

# 确保模块在重启后自动加载
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

echo "[3/6] 安装 Containerd..."
apt install -y containerd

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# 修改 containerd 配置以使用 systemd cgroup 驱动
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "[4/6] 安装 kubeadm/kubelet/kubectl..."
# 下载新的 GPG 密钥
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# 添加新的仓库
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

# 更新并安装
apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "[5/6] 初始化 Kubernetes 集群..."
kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket unix:///run/containerd/containerd.sock

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "[安装 Flannel 网络插件]"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "[6/6] 安装 KubeSphere 控制台..."
# 等待节点就绪
echo "等待节点就绪..."
kubectl wait --for=condition=Ready node --all --timeout=300s

# 安装 KubeSphere
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml

echo ""
echo "✅ Master 节点安装完成！"
echo ""
echo "🔑 请保存以下 join 命令给 Worker 节点加入："
echo "======================================================================"
kubeadm token create --print-join-command
echo "======================================================================"
echo ""
echo "📊 KubeSphere 控制台信息："
echo "地址: http://$(hostname -I | awk '{print $1}'):30880"
echo "用户: admin"
echo "密码: P@88w0rd"
echo ""
echo "🔍 查看 KubeSphere 安装进度："
echo "kubectl logs -n kubesphere-system deployment/ks-installer -f"
echo ""
echo "🎉 安装完成！请等待 5-10 分钟后访问控制台。"
