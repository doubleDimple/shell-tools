#!/bin/bash
# Worker 节点安装脚本

set -e

echo "[1/4] 安装依赖..."
if [ -f /etc/debian_version ]; then
  apt update -y
  apt install -y curl wget socat conntrack ebtables ipset apt-transport-https ca-certificates gnupg lsb-release
elif [ -f /etc/redhat-release ]; then
  yum install -y curl wget socat conntrack ebtables ipset yum-utils device-mapper-persistent-data lvm2
fi

echo "[2/4] 关闭 swap & 配置内核..."
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

echo "[3/4] 安装 Containerd..."
if [ -f /etc/debian_version ]; then
  apt install -y containerd
elif [ -f /etc/redhat-release ]; then
  yum install -y containerd
fi
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "[4/4] 安装 kubeadm/kubelet/kubectl..."
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

echo "✅ Worker 节点准备完成"
echo "现在请执行 Master 节点生成的 join 命令，例如："
echo "kubeadm join 192.168.0.10:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
