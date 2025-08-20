#!/bin/bash
# 诊断并修复 Containerd CRI 问题
set -e

echo "🔍 步骤1: 诊断当前状态..."

echo "检查 containerd 服务状态:"
systemctl status containerd --no-pager || true

echo -e "\n检查 containerd 配置文件:"
if [ -f /etc/containerd/config.toml ]; then
    echo "配置文件存在，检查 CRI 插件配置:"
    grep -n "disabled_plugins" /etc/containerd/config.toml || echo "未找到 disabled_plugins 配置"
    grep -n "SystemdCgroup" /etc/containerd/config.toml || echo "未找到 SystemdCgroup 配置"
else
    echo "配置文件不存在!"
fi

echo -e "\n检查 containerd 进程:"
ps aux | grep containerd | grep -v grep || echo "containerd 进程未运行"

echo -e "\n🛠️ 步骤2: 彻底重新安装并配置 containerd..."

# 停止所有相关服务
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true

# 完全清理
kubeadm reset -f 2>/dev/null || true
apt remove --purge -y containerd 2>/dev/null || true
rm -rf /etc/containerd
rm -rf /var/lib/containerd
rm -rf /run/containerd

echo "重新安装 containerd..."
apt update
apt install -y containerd

echo "创建正确的 containerd 配置..."
mkdir -p /etc/containerd

# 创建一个简化但正确的配置
cat > /etc/containerd/config.toml << 'EOF'
version = 2

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".containerd]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"
EOF

echo "启动 containerd..."
systemctl daemon-reload
systemctl enable containerd
systemctl start containerd

# 等待服务启动
sleep 5

echo "验证 containerd 状态..."
systemctl status containerd --no-pager

echo "测试 CRI 接口..."
crictl --runtime-endpoint unix:///run/containerd/containerd.sock version

echo -e "\n✅ Containerd 配置完成!"
echo -e "\n🚀 步骤3: 重新初始化 Kubernetes 集群..."

# 重新初始化
kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket unix:///run/containerd/containerd.sock

# 配置 kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "安装网络插件..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "等待节点就绪..."
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "安装 KubeSphere..."
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml

echo -e "\n🎉 安装完成!"
echo -e "\n🔑 Worker 节点加入命令:"
echo "================================================================"
kubeadm token create --print-join-command
echo "================================================================"
echo -e "\n📊 KubeSphere 控制台:"
echo "地址: http://$(hostname -I | awk '{print $1}'):30880"
echo "用户: admin"
echo "密码: P@88w0rd"
