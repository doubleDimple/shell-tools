#!/bin/bash
# 修复 Containerd 配置并重新初始化集群
set -e

echo "🔧 修复 Containerd 配置..."

# 停止相关服务
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd

# 清理可能的旧配置
kubeadm reset -f 2>/dev/null || true

# 重新配置 containerd
echo "重新配置 containerd..."
rm -f /etc/containerd/config.toml

# 生成新的默认配置
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# 修改配置启用 CRI 插件并使用 systemd cgroup
sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 重启 containerd
systemctl restart containerd
systemctl enable containerd

# 验证 containerd 状态
echo "验证 containerd 状态..."
sleep 3
systemctl status containerd --no-pager

# 测试 CRI 连接
echo "测试 CRI 连接..."
crictl --runtime-endpoint unix:///run/containerd/containerd.sock version

echo "✅ Containerd 配置修复完成!"
echo ""
echo "🚀 重新初始化 Kubernetes 集群..."

# 重新初始化集群
kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket unix:///run/containerd/containerd.sock

# 配置 kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "安装 Flannel 网络插件..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "安装 KubeSphere..."
# 等待节点就绪
kubectl wait --for=condition=Ready node --all --timeout=300s

# 安装 KubeSphere
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml

echo ""
echo "✅ 安装完成！"
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
echo "🔍 查看安装进度："
echo "kubectl logs -n kubesphere-system deployment/ks-installer -f"
