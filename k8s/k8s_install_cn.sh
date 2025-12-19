#!/usr/bin/env bash
# =========================================================
#  K8s 国内阿里云 ONLY 一键安装脚本
#  - Ubuntu / Debian
#  - containerd + kubeadm
#  - 所有镜像强制走 registry.aliyuncs.com
# =========================================================

set -euo pipefail

### 配置 ###
ALIYUN_REPO="registry.aliyuncs.com/google_containers"
POD_CIDR_FLANNEL="10.244.0.0/16"
POD_CIDR_CALICO="192.168.0.0/16"

### 变量 ###
HOSTNAME_ARG=""
IS_MASTER=0
NETWORK=""
K8S_MINOR="v1.34"

### 颜色 ###
red="\033[31m"; green="\033[32m"; yellow="\033[33m"; blue="\033[36m"; end="\033[0m"

log(){ echo -e "${green}[INFO]${end} $*"; }
warn(){ echo -e "${yellow}[WARN]${end} $*"; }
err(){ echo -e "${red}[ERROR]${end} $*"; exit 1; }

usage(){
cat <<EOF
Usage:
  Master:
    bash $0 --hostname k8s-master-1 --flannel -v 1.34.3
  Worker:
    bash $0 --hostname k8s-worker-1 -v 1.34.3
Options:
  --hostname <name>
  --flannel | --calico
  -v | --version <x.y.z>
EOF
}

### 参数解析 ###
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME_ARG="$2"; shift ;;
    --flannel) NETWORK="flannel"; IS_MASTER=1 ;;
    --calico)  NETWORK="calico";  IS_MASTER=1 ;;
    -v|--version)
      if [[ "$2" =~ ^([0-9]+)\.([0-9]+) ]]; then
        K8S_MINOR="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
      fi
      shift ;;
    -h|--help) usage; exit 0 ;;
  esac
  shift
done

### 前置检查 ###
[[ "$(id -u)" == "0" ]] || err "必须 root 执行"
grep -qiE 'ubuntu|debian' /etc/os-release || err "仅支持 Ubuntu / Debian"

### hostname ###
if [[ -n "$HOSTNAME_ARG" ]]; then
  HOSTNAME_ARG="${HOSTNAME_ARG//_/-}"
  hostnamectl set-hostname "$HOSTNAME_ARG"
  grep -q "$HOSTNAME_ARG" /etc/hosts || echo "127.0.0.1 $HOSTNAME_ARG" >> /etc/hosts
fi

### 系统参数 ###
log "关闭 swap / 开启转发"
swapoff -a || true
sed -i.bak '/ swap / s/^/#/' /etc/fstab

cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
EOF
modprobe br_netfilter || true
sysctl --system

### 安装依赖 ###
log "安装基础依赖"
apt-get update -y
apt-get install -y curl ca-certificates gpg bash-completion apt-transport-https

### 安装 containerd ###
log "安装 containerd"
apt-get install -y containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

### ★★★ 关键：阿里 registry mirror ★★★
log "配置 containerd 阿里云镜像（registry.mirrors）"

cat >> /etc/containerd/config.toml <<EOF

[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
      endpoint = ["https://registry.aliyuncs.com"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["https://registry.aliyuncs.com"]
EOF

systemctl daemon-reexec
systemctl enable containerd
systemctl restart containerd

### 测试阿里镜像 ###
log "测试阿里镜像可达性"
ctr -n k8s.io image pull ${ALIYUN_REPO}/pause:3.10 || err "阿里镜像不可达"

### K8s 安装源（阿里云）###
log "配置阿里云 kubernetes-new 源"
mkdir -p /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/${K8S_MINOR}/deb/Release.key \
 | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/${K8S_MINOR}/deb/ /" \
 > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

### 预拉镜像（阿里）###
log "预拉 K8s 镜像（阿里）"
kubeadm config images pull --image-repository ${ALIYUN_REPO}

### kubeadm init ###
if [[ "$IS_MASTER" == "1" ]]; then
  [[ -n "$NETWORK" ]] || err "Master 必须指定 --flannel 或 --calico"

  POD_CIDR="$POD_CIDR_FLANNEL"
  [[ "$NETWORK" == "calico" ]] && POD_CIDR="$POD_CIDR_CALICO"

  log "初始化 Master（阿里镜像）"
  kubeadm init \
    --image-repository ${ALIYUN_REPO} \
    --pod-network-cidr=${POD_CIDR}

  mkdir -p $HOME/.kube
  cp /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  if [[ "$NETWORK" == "flannel" ]]; then
    kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
  else
    kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
  fi

  log "✅ Master 安装完成"
  log "👉 Worker 加入命令："
  kubeadm token create --print-join-command
else
  warn "Worker 模式：仅安装基础环境"
fi

log "🎉 完成（国内阿里云 ONLY）"
