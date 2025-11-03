#!/usr/bin/env bash
# ================================================================
# 🚀 Rancher + Kubernetes 一键安装脚本 (智能可重入增强版 v4)
# 作者: doubleDimple
# 特点:
#   - 自动检测 Debian / Ubuntu
#   - 自动修复 K8s GPG 错误
#   - 可重复执行 (幂等)
#   - 自动根据参数选择域名模式或 IP:端口模式
#   - 不自动申请证书, 让用户自由配置
#   - 如果指定域名就执行 sudo ./install-rancher.sh rancher.mydomain.com
#   - 如果不指定域名,就执行 sudo ./install-rancher.sh
# ================================================================

set -e
CUSTOM_DOMAIN=$1
GREEN="\\033[32m"; RESET="\\033[0m"

echo -e "${GREEN}🧩 启动 Rancher 智能安装脚本...${RESET}"

# =================== 系统检测 ===================
if grep -qi "ubuntu" /etc/os-release; then
    DISTRO="ubuntu"
elif grep -qi "debian" /etc/os-release; then
    DISTRO="debian"
else
    echo "❌ 仅支持 Debian/Ubuntu"; exit 1
fi

# =================== 系统准备 ===================
echo -e "${GREEN}🧹 更新系统依赖...${RESET}"
sudo apt update -y && sudo apt install -y curl ca-certificates gnupg lsb-release

echo -e "${GREEN}🔧 关闭 swap...${RESET}"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

echo -e "${GREEN}⚙️ 配置内核转发...${RESET}"
sudo modprobe overlay && sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf >/dev/null
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sudo sysctl --system >/dev/null

# =================== 安装 containerd ===================
if ! command -v containerd >/dev/null 2>&1; then
  echo -e "${GREEN}🐳 安装 containerd...${RESET}"
  curl -fsSL https://download.docker.com/linux/${DISTRO}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/${DISTRO} $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update && sudo apt install -y containerd.io
  sudo mkdir -p /etc/containerd && containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl enable --now containerd
else
  echo -e "${GREEN}✅ containerd 已存在, 跳过${RESET}"
fi

# =================== 安装 kubelet / kubeadm / kubectl ===================
if ! command -v kubeadm >/dev/null 2>&1; then
  echo -e "${GREEN}📦 安装 Kubernetes 核心组件...${RESET}"
  sudo mkdir -p /etc/apt/keyrings
  sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  sudo apt update && sudo apt install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl
else
  echo -e "${GREEN}✅ Kubernetes 已安装, 跳过${RESET}"
fi

# =================== 初始化集群 ===================
if ! kubectl get nodes >/dev/null 2>&1; then
  echo -e "${GREEN}🚀 初始化 K8s 集群...${RESET}"
  sudo kubeadm init --pod-network-cidr=10.244.0.0/16
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
else
  echo -e "${GREEN}✅ 集群已存在, 跳过初始化${RESET}"
fi

# =================== 安装 Flannel ===================
if ! kubectl get pods -n kube-flannel >/dev/null 2>&1; then
  echo -e "${GREEN}🌐 安装 Flannel 网络插件...${RESET}"
  kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
else
  echo -e "${GREEN}✅ Flannel 已存在, 跳过${RESET}"
fi

# =================== 安装 Helm ===================
if ! command -v helm >/dev/null 2>&1; then
  echo -e "${GREEN}📦 安装 Helm...${RESET}"
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo -e "${GREEN}✅ Helm 已安装, 跳过${RESET}"
fi

# =================== 安装 cert-manager ===================
if ! kubectl get ns cert-manager >/dev/null 2>&1; then
  echo -e "${GREEN}🔒 安装 cert-manager...${RESET}"
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.crds.yaml
  helm repo add jetstack https://charts.jetstack.io && helm repo update
  helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.15.0
else
  echo -e "${GREEN}✅ cert-manager 已安装, 跳过${RESET}"
fi

# =================== 安装 Rancher ===================
if ! kubectl get ns cattle-system >/dev/null 2>&1; then
  echo -e "${GREEN}🌍 安装 Rancher...${RESET}"
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
  helm repo update
  kubectl create namespace cattle-system || true

  IP=$(curl -s ifconfig.me)
  if [ -n "$CUSTOM_DOMAIN" ]; then
      echo -e "${GREEN}🔧 使用自定义域名: $CUSTOM_DOMAIN${RESET}"
      helm install rancher rancher-latest/rancher \
        --namespace cattle-system \
        --set hostname=$CUSTOM_DOMAIN \
        --set ingress.tls.source=rancher
  else
      echo -e "${GREEN}💡 未指定域名, 使用 IP NodePort 模式${RESET}"
      helm install rancher rancher-latest/rancher \
        --namespace cattle-system \
        --set hostname=${IP}.nip.io \
        --set service.type=NodePort \
        --set ingress.tls.source=rancher
  fi
else
  echo -e "${GREEN}✅ Rancher 已安装, 跳过${RESET}"
fi

# =================== 打印访问信息 ===================
echo -e "${GREEN}🌐 Rancher 部署完成${RESET}"
if [ -n "$CUSTOM_DOMAIN" ]; then
  echo -e "👉 请访问: https://${CUSTOM_DOMAIN}"
else
  PORT=$(kubectl get svc -n cattle-system rancher -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
  echo -e "👉 请访问: https://${IP}:${PORT}"
fi
echo -e "${GREEN}✅ 安装完成！${RESET}"
