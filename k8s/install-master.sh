#!/bin/bash
# Master 节点安装脚本 (修复版)
set -e

echo "[1/6] 更新系统并安装依赖..."
if [ -f /etc/debian_version ]; then
  apt update -y
  apt install -y curl wget socat conntrack ebtables ipset apt-transport-https ca-certificates gnupg lsb-release
elif [ -f /etc/redhat-release ]; then
  yum install -y curl wget socat conntrack ebtables ipset yum-utils device-mapper-persistent-data lvm2
fi

echo "[2/6] 关闭 swap & 配置内核参数..."
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 加载必需的内核模块
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

echo "[3/6] 安装 Containerd..."
if [ -f /etc/debian_version ]; then
  apt install -y containerd
elif [ -f /etc/redhat-release ]; then
  yum install -y containerd
fi

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# 修改 containerd 配置以使用 systemd cgroup 驱动
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "[4/6] 安装 kubeadm/kubelet/kubectl..."
if [ -f /etc/debian_version ]; then
  # 使用新的 Kubernetes 仓库
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
  apt update
  apt install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
elif [ -f /etc/redhat-release ]; then
  cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
  yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
fi

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

echo "✅ Master 节点安装完成"
echo ""
echo "🔑 请保存以下 join 命令给 Worker 节点加入："
echo "--------------------------------------------------------------------"
kubeadm token create --print-join-command
echo "--------------------------------------------------------------------"
echo ""
echo "📊 KubeSphere 正在安装中，请稍等几分钟后访问："
echo "http://$(hostname -I | awk '{print $1}'):30880"
echo ""
echo "🔍 查看 KubeSphere 安装进度："
echo "kubectl logs -n kubesphere-system deployment/ks-installer -f"
