#!/bin/bash
# 使用 Docker 作为容器运行时的 Kubernetes 安装脚本
set -e

echo "🔄 切换到 Docker 容器运行时..."

# 清理之前的安装
echo "清理之前的配置..."
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true
kubeadm reset -f 2>/dev/null || true

# 卸载 containerd
apt remove --purge -y containerd 2>/dev/null || true
rm -rf /etc/containerd

echo "[1/6] 安装 Docker..."
# 安装 Docker
apt update
apt install -y ca-certificates curl gnupg lsb-release

# 添加 Docker 官方 GPG 密钥
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# 设置 Docker 仓库
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 安装 Docker Engine
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# 启动 Docker
systemctl enable docker
systemctl start docker

echo "[2/6] 配置 Docker 为 systemd cgroup..."
# 配置 Docker 使用 systemd cgroup 驱动
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

# 重启 Docker
systemctl daemon-reload
systemctl restart docker

echo "[3/6] 配置内核参数..."
# 确保必要的内核模块已加载
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "[4/6] 验证 Docker 状态..."
docker version
systemctl status docker --no-pager

echo "[5/6] 初始化 Kubernetes 集群..."
# 使用 Docker 作为容器运行时初始化集群
kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket unix:///var/run/cri-dockerd.sock 2>/dev/null || \
kubeadm init --pod-network-cidr=10.244.0.0/16

# 配置 kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "[6/6] 安装网络插件和 KubeSphere..."
# 安装 Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 等待节点就绪
echo "等待节点就绪..."
kubectl wait --for=condition=Ready node --all --timeout=300s

# 安装 KubeSphere
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml

echo ""
echo "🎉 安装完成！"
echo ""
echo "🔑 Worker 节点加入命令："
echo "================================================================"
kubeadm token create --print-join-command
echo "================================================================"
echo ""
echo "📊 KubeSphere 控制台："
echo "地址: http://$(hostname -I | awk '{print $1}'):30880"
echo "用户: admin"  
echo "密码: P@88w0rd"
echo ""
echo "🔍 查看 KubeSphere 安装进度："
echo "kubectl logs -n kubesphere-system deployment/ks-installer -f"
echo ""
echo "⚠️  注意：KubeSphere 完全启动需要 5-10 分钟，请耐心等待。"
