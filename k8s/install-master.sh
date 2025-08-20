#!/bin/bash
# Master 节点安装脚本

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
systemctl restart containerd
systemctl enable containerd

echo "[4/6] 安装 kubeadm/kubelet/kubectl..."
if [ -f /etc/debian_version ]; then
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
  apt update
  apt install -y kubelet kubeadm kubectl
elif [ -f /etc/redhat-release ]; then
  cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
EOF
  yum install -y kubelet kubeadm kubectl
fi
systemctl enable kubelet

echo "[5/6] 初始化 Kubernetes 集群..."
kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "[安装 Flannel 网络插件]"
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "[6/6] 安装 KubeSphere 控制台..."
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml

echo "✅ Master 节点安装完成"
echo "请保存以下 join 命令给 Worker 节点加入："
kubeadm token create --print-join-command
