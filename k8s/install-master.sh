#!/bin/bash
# Kubernetes 完整安装脚本 - 解决 CRI 和版本问题
set -e

echo "🚀 Kubernetes 完整重新安装脚本 v2.0"
echo "解决 CRI 接口和版本兼容性问题"

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "❌ 此脚本需要 root 权限运行"
   echo "请使用: sudo $0"
   exit 1
fi

# 检查系统版本
echo "系统信息:"
lsb_release -a

echo ""
echo "🧹 [1/10] 彻底清理系统..."

# 停止所有服务
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true
systemctl stop docker 2>/dev/null || true

# 重置 kubeadm
kubeadm reset -f 2>/dev/null || true

# 彻底卸载所有相关软件包
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt remove --purge -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
apt remove --purge -y docker-ce docker-ce-cli containerd.io containerd 2>/dev/null || true
apt remove --purge -y docker-buildx-plugin docker-compose-plugin 2>/dev/null || true

# 清理残留文件
rm -rf ~/.kube /etc/kubernetes /var/lib/kubelet /var/lib/etcd
rm -rf /etc/docker /etc/containerd /var/lib/containerd /opt/containerd
rm -rf /etc/systemd/system/kubelet.service.d
rm -rf /etc/apt/sources.list.d/kubernetes*.list
rm -rf /etc/apt/sources.list.d/docker.list
rm -rf /etc/apt/keyrings/kubernetes*.gpg
rm -rf /etc/apt/keyrings/docker.gpg
rm -rf /etc/crictl.yaml

# 清理网络
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true

# 清理 iptables 规则
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true

apt autoremove -y
apt autoclean

echo "✅ 清理完成"

echo ""
echo "📦 [2/10] 安装系统依赖..."
apt update
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common

echo ""
echo "🔧 [3/10] 配置内核参数..."
# 配置内核模块
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 配置系统参数
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo ""
echo "🐳 [4/10] 安装最新版 containerd..."

# 添加 Docker 官方仓库
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y containerd.io

echo ""
echo "🔧 [5/10] 配置 containerd..."

# 停止 containerd 服务
systemctl stop containerd

# 创建配置目录
mkdir -p /etc/containerd

# 生成默认配置
containerd config default > /etc/containerd/config.toml

# 修改配置文件以启用 systemd cgroup 和 CRI
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 确保 CRI 插件未被禁用
sed -i '/disabled_plugins.*cri/d' /etc/containerd/config.toml

# 启动 containerd
systemctl daemon-reload
systemctl enable containerd
systemctl start containerd

# 等待服务启动
sleep 10

echo "验证 containerd 状态:"
systemctl status containerd --no-pager

echo ""
echo "☸️  [6/10] 安装 Kubernetes 1.29..."

# 添加 Kubernetes apt 仓库
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

apt update

# 安装指定版本确保兼容性
apt install -y kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo ""
echo "🔧 [7/10] 配置 CRI 接口..."

# 安装 cri-tools
apt install -y cri-tools

# 配置 crictl
cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
EOF

echo ""
echo "🔍 [8/10] 验证安装..."

echo "containerd 版本:"
containerd --version

echo "crictl 版本:"
crictl version

echo "kubeadm 版本:"
kubeadm version

echo "kubelet 版本:"
kubelet --version

echo "kubectl 版本:"
kubectl version --client

# 测试 CRI 连接
echo "测试 CRI 连接:"
crictl info | head -20

echo ""
echo "🎯 [9/10] 初始化 Kubernetes 集群..."

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

# 移除 master 污点
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo ""
echo "🌐 [10/10] 安装网络插件..."

# 安装 Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 等待节点就绪
echo "等待节点就绪..."
kubectl wait --for=condition=Ready node --all --timeout=300s || true

# 安装 KubeSphere
echo "安装 KubeSphere..."
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml

echo ""
echo "🎉 安装完成！"
echo "================================================================"

# 显示集群状态
echo "集群节点状态:"
kubectl get nodes -o wide

echo ""
echo "系统 Pods 状态:"
kubectl get pods -n kube-system

echo ""
echo "================================================================"
echo "🔑 Worker 节点加入命令："
kubeadm token create --print-join-command
echo "================================================================"

echo ""
echo "📊 KubeSphere 控制台："
echo "地址: http://$LOCAL_IP:30880"
echo "用户: admin"
echo "密码: P@88w0rd"

echo ""
echo "🔍 监控命令："
echo "kubectl get pods --all-namespaces               # 查看所有 Pod"
echo "kubectl logs -n kubesphere-system deployment/ks-installer -f  # KubeSphere 安装日志"
echo "systemctl status kubelet                        # kubelet 状态"
echo "systemctl status containerd                     # containerd 状态"
echo "crictl ps                                       # 容器列表"

echo ""
echo "⚠️  注意："
echo "1. KubeSphere 完全启动需要 5-10 分钟"
echo "2. 如果是云服务器，请开放 6443 和 30880 端口"
echo "3. 建议首次登录后修改默认密码"

echo ""
echo "✅ 脚本执行完毕！请等待所有 Pod 启动完成。"
