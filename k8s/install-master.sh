#!/bin/bash
# Kubernetes + 多控制台选择安装脚本 - 支持 Ubuntu/Debian/CentOS/RHEL
set -e

echo "🚀 Kubernetes + 多控制台选择安装脚本 v6.1 (网络修复版)"
echo "支持 Ubuntu/Debian/CentOS/RHEL 系统 - 强制清理重装"

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "❌ 此脚本需要 root 权限运行"
   echo "请使用: sudo $0"
   exit 1
fi

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        
        # 特别处理一些系统的识别
        case $ID in
            ubuntu)
                OS="ubuntu"
                CODENAME=$VERSION_CODENAME
                ;;
            debian)
                OS="debian" 
                CODENAME=$VERSION_CODENAME
                ;;
            centos|rhel|rocky|almalinux)
                OS=$ID
                ;;
            *)
                # 如果检测不到，通过文件判断
                if [ -f /etc/debian_version ]; then
                    if grep -q "ubuntu" /etc/os-release 2>/dev/null; then
                        OS="ubuntu"
                    else
                        OS="debian"
                    fi
                    CODENAME=$(lsb_release -cs 2>/dev/null || echo "bullseye")
                elif [ -f /etc/redhat-release ]; then
                    OS="centos"
                fi
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        CODENAME=$(lsb_release -cs 2>/dev/null || echo "bullseye")
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
    else
        echo "❌ 无法检测系统类型"
        exit 1
    fi
    
    echo "检测到系统: $OS"
    if [ -n "$OS_VERSION" ]; then
        echo "系统版本: $OS_VERSION"
    fi
    if [ -n "$CODENAME" ]; then
        echo "代码名: $CODENAME"
    fi
    
    # 设置包管理器
    case $OS in
        ubuntu|debian)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            fi
            ;;
        *)
            echo "❌ 不支持的系统: $OS"
            exit 1
            ;;
    esac
    
    echo "使用包管理器: $PKG_MANAGER"
}

# 强制清理所有 Kubernetes 相关组件
force_cleanup() {
    echo ""
    echo "🧹 [1/13] 强制清理所有 Kubernetes 组件..."
    
    # 停止相关服务（保留 Docker）
    echo "停止相关服务..."
    systemctl stop kubelet 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
    systemctl stop cri-docker 2>/dev/null || true
    
    # 强制杀死相关进程（保留 Docker）
    echo "杀死相关进程..."
    pkill -9 -f kubelet 2>/dev/null || true
    pkill -9 -f kube-proxy 2>/dev/null || true
    pkill -9 -f kube-apiserver 2>/dev/null || true
    pkill -9 -f kube-controller 2>/dev/null || true
    pkill -9 -f kube-scheduler 2>/dev/null || true
    pkill -9 -f etcd 2>/dev/null || true
    pkill -9 -f containerd 2>/dev/null || true
    # 注意：不杀死 dockerd 进程，保留 Docker
    
    # 等待进程完全停止
    sleep 5
    
    # 重置 kubeadm（如果存在）
    echo "重置 kubeadm..."
    kubeadm reset -f 2>/dev/null || true
    
    # 卸载软件包（保留 Docker）
    echo "卸载 Kubernetes 相关软件包..."
    case $PKG_MANAGER in
        apt)
            apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
            apt remove --purge -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
            apt remove --purge -y containerd.io containerd 2>/dev/null || true
            apt remove --purge -y cri-tools 2>/dev/null || true
            # 注意：不卸载 Docker 相关包
            # apt remove --purge -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin
            apt autoremove -y 2>/dev/null || true
            apt autoclean 2>/dev/null || true
            ;;
        yum|dnf)
            $PKG_MANAGER remove -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
            $PKG_MANAGER remove -y containerd.io containerd 2>/dev/null || true
            $PKG_MANAGER remove -y cri-tools 2>/dev/null || true
            # 注意：不卸载 Docker 相关包
            # $PKG_MANAGER remove -y docker-ce docker-ce-cli
            $PKG_MANAGER autoremove -y 2>/dev/null || true
            ;;
    esac
    
    # 清理文件和目录（保留 Docker 数据）
    echo "清理文件和目录..."
    rm -rf ~/.kube
    rm -rf /etc/kubernetes
    rm -rf /var/lib/kubelet
    rm -rf /var/lib/etcd
    rm -rf /etc/containerd
    rm -rf /var/lib/containerd
    rm -rf /opt/containerd
    # 注意：保留 Docker 目录
    # rm -rf /etc/docker
    # rm -rf /var/lib/docker
    rm -rf /opt/cni
    rm -rf /etc/cni
    rm -rf /var/lib/cni
    rm -rf /run/flannel
    rm -rf /etc/systemd/system/kubelet.service.d
    # 注意：保留 Docker systemd 配置
    # rm -rf /etc/systemd/system/docker.service.d
    rm -rf /lib/systemd/system/kubelet.service
    rm -rf /etc/crictl.yaml
    
    # 清理仓库配置（保留 Docker 仓库）
    echo "清理仓库配置..."
    rm -rf /etc/apt/sources.list.d/kubernetes*.list
    rm -rf /etc/yum.repos.d/kubernetes.repo
    rm -rf /etc/apt/keyrings/kubernetes*.gpg
    # 注意：保留 Docker 仓库配置
    # rm -rf /etc/apt/sources.list.d/docker*.list
    # rm -rf /etc/yum.repos.d/docker*.repo
    # rm -rf /etc/apt/keyrings/docker*.gpg
    
    # 清理网络接口
    echo "清理网络接口..."
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    ip link delete kube-bridge 2>/dev/null || true
    # 注意：保留 docker0 网桥
    # ip link delete docker0 2>/dev/null || true
    
    # 清理 iptables 规则（只清理 Kubernetes 相关）
    echo "清理 Kubernetes iptables 规则..."
    # 清理 Kubernetes 相关的 iptables 规则，但保留 Docker 规则
    iptables-save | grep -v KUBE | iptables-restore 2>/dev/null || {
        # 如果上面的方法失败，使用传统方法但更小心
        iptables -t filter -D FORWARD -j DOCKER-USER 2>/dev/null || true
        iptables -t filter -D FORWARD -j DOCKER-ISOLATION-STAGE-1 2>/dev/null || true
        # 清理其他非 Docker 规则
        iptables -F INPUT 2>/dev/null || true
        iptables -F OUTPUT 2>/dev/null || true
        iptables -t nat -F OUTPUT 2>/dev/null || true
        iptables -t nat -F PREROUTING 2>/dev/null || true
    }
    
    # 清理 systemd 服务
    echo "清理 systemd 服务..."
    systemctl daemon-reload
    systemctl reset-failed
    
    # 强制卸载残留的挂载点
    echo "清理挂载点..."
    umount /var/lib/kubelet/pods/*/volumes/kubernetes.io~secret/* 2>/dev/null || true
    umount /var/lib/kubelet/pods/*/volumes/kubernetes.io~configmap/* 2>/dev/null || true
    umount /var/lib/kubelet/* 2>/dev/null || true
    
    # 检查并杀死占用 Kubernetes 关键端口的进程（不影响 Docker）
    echo "检查 Kubernetes 关键端口..."
    for port in 6443 10250 10251 10252 2379 2380; do
        PID=$(lsof -ti :$port 2>/dev/null || true)
        if [ -n "$PID" ]; then
            echo "杀死占用端口 $port 的进程 $PID"
            kill -9 $PID 2>/dev/null || true
        fi
    done
    
    echo "✅ Kubernetes 组件清理完成（Docker 已保留）"
}

# 更新系统函数
update_system() {
    case $PKG_MANAGER in
        apt)
            apt update
            ;;
        yum|dnf)
            $PKG_MANAGER update -y
            ;;
    esac
}

# 安装基础包函数
install_basic_packages() {
    case $PKG_MANAGER in
        apt)
            apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common wget
            ;;
        yum|dnf)
            $PKG_MANAGER install -y curl gnupg2 software-properties-common yum-utils device-mapper-persistent-data lvm2 wget
            ;;
    esac
}

# 安装 containerd 函数
install_containerd() {
    case $OS in
        ubuntu)
            # Ubuntu
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt update
            apt install -y containerd.io
            ;;
        debian)
            # Debian
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt update
            apt install -y containerd.io
            ;;
        centos|rhel|rocky|almalinux)
            # CentOS/RHEL
            $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            $PKG_MANAGER install -y containerd.io
            ;;
    esac
}

# 安装 Kubernetes 函数
install_kubernetes() {
    case $PKG_MANAGER in
        apt)
            # Ubuntu/Debian
            curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
            echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
            apt update
            apt install -y kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1
            apt-mark hold kubelet kubeadm kubectl
            ;;
        yum|dnf)
            # CentOS/RHEL
            cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF
            $PKG_MANAGER install -y kubelet-1.29.0 kubeadm-1.29.0 kubectl-1.29.0 --disableexcludes=kubernetes
            ;;
    esac
}

# 安装 Helm
install_helm() {
    echo "安装 Helm..."
    if ! command -v helm &> /dev/null; then
        curl https://get.helm.sh/helm-v3.12.1-linux-amd64.tar.gz -o helm.tar.gz
        tar -zxvf helm.tar.gz
        mv linux-amd64/helm /usr/local/bin/helm
        rm -rf helm.tar.gz linux-amd64
        chmod +x /usr/local/bin/helm
    fi
    helm version
}

# 选择控制台类型
choose_dashboard() {
    echo ""
    echo "🎯 选择要安装的控制台："
    echo "1) Kubernetes Dashboard (官方，轻量级，Token 登录)"
    echo "2) Rancher (开源版，功能完整，图形化用户管理)"
    echo "3) KubeSphere (现代化界面，功能丰富，中文支持)"
    echo ""
    while true; do
        read -p "请选择 [1-3]: " DASHBOARD_CHOICE
        case $DASHBOARD_CHOICE in
            1)
                INSTALL_K8S_DASHBOARD=true
                INSTALL_RANCHER=false
                INSTALL_KUBESPHERE=false
                echo "✅ 已选择：Kubernetes Dashboard"
                break
                ;;
            2)
                INSTALL_K8S_DASHBOARD=false
                INSTALL_RANCHER=true
                INSTALL_KUBESPHERE=false
                echo "✅ 已选择：Rancher"
                break
                ;;
            3)
                INSTALL_K8S_DASHBOARD=false
                INSTALL_RANCHER=false
                INSTALL_KUBESPHERE=true
                echo "✅ 已选择：KubeSphere"
                break
                ;;
            *)
                echo "❌ 无效选择，请输入 1、2 或 3"
                ;;
        esac
    done
}

# 开始安装
detect_os

echo ""
echo "📋 系统信息："
echo "操作系统: $OS $OS_VERSION"
echo "包管理器: $PKG_MANAGER"
if [ -n "$CODENAME" ]; then
    echo "代码名: $CODENAME"
fi

# 选择控制台
choose_dashboard

# 强制清理
force_cleanup

echo ""
echo "📦 [2/13] 更新系统并安装依赖..."
update_system
install_basic_packages

echo ""
echo "🔧 [3/13] 配置内核参数..."
# 配置内核模块
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 配置系统参数
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# 禁用 SELinux (对于 RHEL/CentOS)
if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "rocky" ] || [ "$OS" = "almalinux" ]; then
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
fi

# 禁用 swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo ""
echo "🐳 [4/13] 安装 containerd..."
install_containerd

echo ""
echo "🔧 [5/13] 配置 containerd..."

# 停止 containerd 服务
systemctl stop containerd 2>/dev/null || true

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
echo "☸️  [6/13] 安装 Kubernetes 1.29..."
install_kubernetes

# 启动 kubelet
systemctl enable kubelet

echo ""
echo "🔧 [7/13] 配置 CRI 接口..."

# 安装 cri-tools
case $PKG_MANAGER in
    apt)
        apt install -y cri-tools
        ;;
    yum|dnf)
        $PKG_MANAGER install -y cri-tools
        ;;
esac

# 配置 crictl
cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
EOF

echo ""
echo "🛠️ [8/13] 安装 Helm..."
install_helm

echo ""
echo "🔍 [9/13] 验证安装..."

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

echo "helm 版本:"
helm version

# 测试 CRI 连接
echo "测试 CRI 连接:"
crictl info | head -20

echo ""
echo "🎯 [10/13] 初始化 Kubernetes 集群..."

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
    --kubernetes-version=v1.29.0 \
    --ignore-preflight-errors=Port-6443,Port-10250,Port-10251,Port-10252,Port-2379,Port-2380

# 配置 kubectl
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 移除 master 污点
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo ""
echo "🌐 [11/13] 安装网络插件..."

# 停止 kubelet 以确保干净的网络设置
systemctl stop kubelet

# 清理可能存在的网络配置
echo "清理现有网络配置..."
rm -rf /etc/cni/net.d/*
rm -rf /var/lib/cni/*
rm -rf /run/flannel/*
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true

# 创建必要的目录
mkdir -p /run/flannel
mkdir -p /etc/cni/net.d
mkdir -p /opt/cni/bin

# 重启 kubelet
systemctl start kubelet
sleep 10

# 使用稳定的 Flannel 配置
echo "安装优化的 Flannel 网络插件..."
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    k8s-app: flannel
    pod-security.kubernetes.io/enforce: privileged
  name: kube-flannel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: flannel
  name: flannel
  namespace: kube-flannel
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: flannel
  name: flannel
rules:
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
- apiGroups:
  - networking.k8s.io
  resources:
  - clustercidrs
  verbs:
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: flannel
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    app: flannel
    k8s-app: flannel
    tier: node
  name: kube-flannel-cfg
  namespace: kube-flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "1.0.0",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "Backend": {
        "Type": "vxlan"
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    app: flannel
    k8s-app: flannel
    tier: node
  name: kube-flannel-ds
  namespace: kube-flannel
spec:
  selector:
    matchLabels:
      app: flannel
      k8s-app: flannel
  template:
    metadata:
      labels:
        app: flannel
        k8s-app: flannel
        tier: node
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
      containers:
      - args:
        - --ip-masq
        - --kube-subnet-mgr
        command:
        - /opt/bin/flanneld
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: EVENT_QUEUE_DEPTH
          value: "5000"
        image: docker.io/flannel/flannel:v0.24.2
        name: kube-flannel
        resources:
          requests:
            cpu: 100m
            memory: 50Mi
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
          privileged: false
        volumeMounts:
        - mountPath: /run/flannel
          name: run
        - mountPath: /etc/kube-flannel/
          name: flannel-cfg
        - mountPath: /run/xtables.lock
          name: xtables-lock
      hostNetwork: true
      initContainers:
      - args:
        - -f
        - /flannel
        - /opt/cni/bin/flannel
        command:
        - cp
        image: docker.io/flannel/flannel-cni-plugin:v1.4.0-flannel1
        name: install-cni-plugin
        volumeMounts:
        - mountPath: /opt/cni/bin
          name: cni-plugin
      - args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        command:
        - cp
        image: docker.io/flannel/flannel:v0.24.2
        name: install-cni
        volumeMounts:
        - mountPath: /etc/cni/net.d
          name: cni
        - mountPath: /etc/kube-flannel/
          name: flannel-cfg
      priorityClassName: system-node-critical
      serviceAccountName: flannel
      tolerations:
      - effect: NoSchedule
        operator: Exists
      volumes:
      - hostPath:
          path: /run/flannel
        name: run
      - hostPath:
          path: /opt/cni/bin
        name: cni-plugin
      - hostPath:
          path: /etc/cni/net.d
        name: cni
      - configMap:
          name: kube-flannel-cfg
        name: flannel-cfg
      - hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
        name: xtables-lock
EOF

# 等待 Flannel Pod 启动
echo "等待 Flannel Pod 启动（最多 5 分钟）..."
for i in {1..20}; do
    FLANNEL_STATUS=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | grep -v Terminating | awk '{print $3}' | head -1)
    if [ "$FLANNEL_STATUS" = "Running" ]; then
        echo "✅ Flannel 启动成功！"
        break
    elif [ "$FLANNEL_STATUS" = "CrashLoopBackOff" ] || [ "$FLANNEL_STATUS" = "Error" ]; then
        echo "⚠️ Flannel 启动失败，状态: $FLANNEL_STATUS"
        echo "查看详细日志:"
        kubectl logs -n kube-flannel -l app=flannel --tail=20 2>/dev/null || echo "日志暂不可用"
        
        # 修复 Flannel 目录权限
        echo "修复 Flannel 目录权限..."
        mkdir -p /run/flannel
        chmod 755 /run/flannel
        
        # 手动创建 subnet.env 文件
        echo "创建 Flannel subnet.env 文件..."
        cat > /run/flannel/subnet.env << SUBNETEOF
FLANNEL_NETWORK=10.244.0.0/16
FLANNEL_SUBNET=10.244.0.1/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
SUBNETEOF
        
        # 重启 Flannel Pod
        kubectl delete pods -n kube-flannel --all 2>/dev/null || true
        sleep 30
        break
    else
        echo "等待中... (${i}/20) 当前状态: ${FLANNEL_STATUS:-"创建中"}"
        sleep 15
    fi
done

# 确保 /run/flannel/subnet.env 文件存在
if [ ! -f /run/flannel/subnet.env ]; then
    echo "创建 Flannel subnet.env 文件..."
    mkdir -p /run/flannel
    cat > /run/flannel/subnet.env << EOF
FLANNEL_NETWORK=10.244.0.0/16
FLANNEL_SUBNET=10.244.0.1/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
EOF
    chmod 644 /run/flannel/subnet.env
fi

# 等待节点就绪
echo "等待节点就绪..."
kubectl wait --for=condition=Ready node --all --timeout=300s || true

# 检查 CoreDNS
echo "检查 CoreDNS 状态..."
kubectl wait --for=condition=available --timeout=180s deployment/coredns -n kube-system || true

# 最终验证
echo "验证网络配置..."
sleep 15
FLANNEL_FINAL=$(kubectl get pods -n kube-flannel --no-headers | grep Running | wc -l)
if [ "$FLANNEL_FINAL" -eq 0 ]; then
    echo "⚠️  Flannel 仍未正常运行，但继续安装..."
    echo "可以稍后手动修复网络问题"
else
    echo "✅ Flannel 网络配置完成"
fi

echo "✅ 网络插件配置完成"

echo ""
echo "📊 [12/13] 安装控制台..."

# 安装 Kubernetes Dashboard（如果选择）
if [ "$INSTALL_K8S_DASHBOARD" = true ]; then
    echo "安装 Kubernetes Dashboard..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml || {
        echo "GitHub 下载失败，使用备用方式..."
        # 备用方式：内联配置
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: kubernetes-dashboard
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
---
kind: Service
apiVersion: v1
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
spec:
  type: NodePort
  ports:
    - port: 443
      targetPort: 8443
      nodePort: 30443
  selector:
    k8s-app: kubernetes-dashboard
---
apiVersion: v1
kind: Secret
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard-certs
  namespace: kubernetes-dashboard
type: Opaque
---
apiVersion: v1
kind: Secret
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard-csrf
  namespace: kubernetes-dashboard
type: Opaque
data:
  csrf: ""
---
apiVersion: v1
kind: Secret
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard-key-holder
  namespace: kubernetes-dashboard
type: Opaque
---
kind: ConfigMap
apiVersion: v1
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard-settings
  namespace: kubernetes-dashboard
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["kubernetes-dashboard-key-holder", "kubernetes-dashboard-certs", "kubernetes-dashboard-csrf"]
    verbs: ["get", "update", "delete"]
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["kubernetes-dashboard-settings"]
    verbs: ["get", "update"]
  - apiGroups: [""]
    resources: ["services"]
    resourceNames: ["heapster", "dashboard-metrics-scraper"]
    verbs: ["proxy"]
  - apiGroups: [""]
    resources: ["services/proxy"]
    resourceNames: ["heapster", "http:heapster:", "https:heapster:", "dashboard-metrics-scraper", "http:dashboard-metrics-scraper"]
    verbs: ["get"]
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
rules:
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods", "nodes"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kubernetes-dashboard
subjects:
  - kind: ServiceAccount
    name: kubernetes-dashboard
    namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubernetes-dashboard
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubernetes-dashboard
subjects:
  - kind: ServiceAccount
    name: kubernetes-dashboard
    namespace: kubernetes-dashboard
---
kind: Deployment
apiVersion: apps/v1
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
spec:
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      k8s-app: kubernetes-dashboard
  template:
    metadata:
      labels:
        k8s-app: kubernetes-dashboard
    spec:
      containers:
        - name: kubernetes-dashboard
          image: kubernetesui/dashboard:v2.7.0
          imagePullPolicy: Always
          ports:
            - containerPort: 8443
              protocol: TCP
          args:
            - --auto-generate-certificates
            - --namespace=kubernetes-dashboard
          volumeMounts:
            - name: kubernetes-dashboard-certs
              mountPath: /certs
            - mountPath: /tmp
              name: tmp-volume
          livenessProbe:
            httpGet:
              scheme: HTTPS
              path: /
              port: 8443
            initialDelaySeconds: 30
            timeoutSeconds: 30
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsUser: 1001
            runAsGroup: 2001
      volumes:
        - name: kubernetes-dashboard-certs
          secret:
            secretName: kubernetes-dashboard-certs
        - name: tmp-volume
          emptyDir: {}
      serviceAccountName: kubernetes-dashboard
      nodeSelector:
        "kubernetes.io/os": linux
      tolerations:
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
---
kind: Service
apiVersion: v1
metadata:
  labels:
    k8s-app: dashboard-metrics-scraper
  name: dashboard-metrics-scraper
  namespace: kubernetes-dashboard
spec:
  ports:
    - port: 8000
      targetPort: 8000
  selector:
    k8s-app: dashboard-metrics-scraper
---
kind: Deployment
apiVersion: apps/v1
metadata:
  labels:
    k8s-app: dashboard-metrics-scraper
  name: dashboard-metrics-scraper
  namespace: kubernetes-dashboard
spec:
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      k8s-app: dashboard-metrics-scraper
  template:
    metadata:
      labels:
        k8s-app: dashboard-metrics-scraper
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: dashboard-metrics-scraper
          image: kubernetesui/metrics-scraper:v1.0.8
          ports:
            - containerPort: 8000
              protocol: TCP
          livenessProbe:
            httpGet:
              scheme: HTTP
              path: /
              port: 8000
            initialDelaySeconds: 30
            timeoutSeconds: 30
          volumeMounts:
          - mountPath: /tmp
            name: tmp-volume
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsUser: 1001
            runAsGroup: 2001
      serviceAccountName: kubernetes-dashboard
      nodeSelector:
        "kubernetes.io/os": linux
      tolerations:
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
      volumes:
        - name: tmp-volume
          emptyDir: {}
EOF
    }

    # 等待 Dashboard 启动
    echo "等待 Dashboard 启动..."
    kubectl wait --for=condition=available --timeout=300s deployment/kubernetes-dashboard -n kubernetes-dashboard || true

    # 修改服务类型为 NodePort
    echo "配置 Dashboard 外部访问..."
    kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8443,"nodePort":30443}]}}' 2>/dev/null || true

    # 创建管理员用户
    echo "创建 Kubernetes Dashboard 管理员用户..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-user-token
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/service-account-token
EOF

    # 等待 Secret 创建完成
    sleep 5

    # 生成访问令牌
    echo "获取 Kubernetes Dashboard 访问令牌..."
    K8S_TOKEN=$(kubectl get secret admin-user-token -n kubernetes-dashboard -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || echo "Token生成失败")
fi

# 安装 Rancher（如果选择）
if [ "$INSTALL_RANCHER" = true ]; then
    echo "安装 Rancher..."
    
    # 创建 cattle-system 命名空间
    kubectl create namespace cattle-system 2>/dev/null || true
    
    # 创建 Rancher ServiceAccount 和必要权限
    echo "配置 Rancher 权限..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rancher
  namespace: cattle-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rancher
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: rancher
  namespace: cattle-system
EOF
    
    # 检查网络是否就绪
    echo "检查网络连接..."
    NETWORK_READY=false
    for i in {1..3}; do
        if kubectl run network-test --image=busybox --rm -i --restart=Never -- nslookup kubernetes.default > /dev/null 2>&1; then
            NETWORK_READY=true
            break
        fi
        echo "网络检查第 $i 次失败，等待重试..."
        sleep 10
    done
    
    if [ "$NETWORK_READY" = false ]; then
        echo "⚠️  网络连接异常，重启网络组件..."
        kubectl delete pods -n kube-flannel --all 2>/dev/null || true
        sleep 15
    fi
    
    # 部署 Rancher（使用简化的有效配置）
    echo "部署 Rancher..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rancher
  namespace: cattle-system
  labels:
    app: rancher
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rancher
  template:
    metadata:
      labels:
        app: rancher
    spec:
      serviceAccountName: rancher
      hostNetwork: true
      containers:
      - name: rancher
        image: rancher/rancher:v2.7.9
        ports:
        - containerPort: 80
        - containerPort: 443
        env:
        - name: CATTLE_BOOTSTRAP_PASSWORD
          value: "admin123456"
        args:
        - "--add-local=true"
        - "--no-cacerts=true"
        resources:
          requests:
            cpu: "200m"
            memory: "512Mi"
          limits:
            cpu: "1"
            memory: "2Gi"
---
apiVersion: v1
kind: Service
metadata:
  name: rancher
  namespace: cattle-system
  labels:
    app: rancher
spec:
  type: NodePort
  ports:
  - name: http
    port: 80
    targetPort: 80
    nodePort: 30080
  - name: https
    port: 443
    targetPort: 443
    nodePort: 30444
  selector:
    app: rancher
EOF
    
    # 等待 Rancher 启动（智能等待）
    echo "等待 Rancher 启动..."
    echo "这可能需要 2-3 分钟，请耐心等待..."
    
    # 等待 Pod 就绪
    for i in {1..12}; do
        RANCHER_STATUS=$(kubectl get pods -n cattle-system -l app=rancher --no-headers 2>/dev/null | awk '{print $3}' | head -1)
        if [ "$RANCHER_STATUS" = "Running" ]; then
            echo "✅ Rancher 启动成功！"
            break
        elif [ "$RANCHER_STATUS" = "CrashLoopBackOff" ] || [ "$RANCHER_STATUS" = "Error" ]; then
            echo "⚠️  Rancher 启动失败，状态: $RANCHER_STATUS"
            echo "检查日志："
            kubectl logs -n cattle-system -l app=rancher --tail=10 2>/dev/null || echo "日志暂不可用"
            break
        else
            echo "等待中... (${i}/12) 当前状态: ${RANCHER_STATUS:-"创建中"}"
            sleep 15
        fi
    done
    
    # 最终状态检查
    FINAL_STATUS=$(kubectl get pods -n cattle-system -l app=rancher --no-headers 2>/dev/null | awk '{print $3}' | head -1)
    if [ "$FINAL_STATUS" = "Running" ]; then
        echo "🎉 Rancher 部署成功！"
    else
        echo "⚠️  Rancher 当前状态: $FINAL_STATUS"
        echo "可以运行以下命令检查："
        echo "kubectl get pods -n cattle-system"
        echo "kubectl logs -n cattle-system deployment/rancher -f"
    fi
fi

echo ""
echo "🔧 [13/13] 配置完成..."

echo ""
echo "🎉 Kubernetes 集群安装完成！"
echo "================================================================"

# 显示集群状态
echo "集群节点状态:"
kubectl get nodes -o wide

echo ""
echo "系统 Pods 状态:"
kubectl get pods -n kube-system

if [ "$INSTALL_K8S_DASHBOARD" = true ]; then
    echo ""
    echo "Kubernetes Dashboard Pods:"
    kubectl get pods -n kubernetes-dashboard
fi

if [ "$INSTALL_RANCHER" = true ]; then
    echo ""
    echo "Rancher Pods:"
    kubectl get pods -n cattle-system
fi

if [ "$INSTALL_KUBESPHERE" = true ]; then
    echo ""
    echo "KubeSphere Pods:"
    kubectl get pods -n kubesphere-system
fi

echo ""
echo "================================================================"
echo "🔑 Worker 节点加入命令："
kubeadm token create --print-join-command
echo "================================================================"

echo ""
echo "📊 控制台访问信息："

if [ "$INSTALL_K8S_DASHBOARD" = true ]; then
    echo ""
    echo "🎯 Kubernetes Dashboard:"
    echo "地址: https://$LOCAL_IP:30443"
    echo "登录方式: Token"
    echo "访问令牌:"
    echo "$K8S_TOKEN"
fi

if [ "$INSTALL_RANCHER" = true ]; then
    echo ""
    echo "🎯 Rancher 控制台:"
    echo "地址: https://$LOCAL_IP:30444"
    echo "备用地址: http://$LOCAL_IP:30080"
    echo "初始用户名: admin"
    echo "初始密码: admin123456"
    echo "⚠️  首次登录后请设置新密码"
fi

if [ "$INSTALL_KUBESPHERE" = true ]; then
    echo ""
    echo "🎯 KubeSphere 控制台:"
    echo "地址: http://$LOCAL_IP:30880"
    echo "默认用户名: admin"
    echo "默认密码: P@88w0rd"
    echo "⚠️  首次登录后请及时修改默认密码"
    echo "💡 KubeSphere 支持完整的用户管理和中文界面"
fi

echo ""
echo "🔍 监控命令："
echo "kubectl get pods --all-namespaces                              # 查看所有 Pod"

if [ "$INSTALL_K8S_DASHBOARD" = true ]; then
    echo "kubectl get svc -n kubernetes-dashboard                        # 查看 Dashboard 服务"
    echo "kubectl -n kubernetes-dashboard create token admin-user        # 重新生成 Dashboard 令牌"
fi

if [ "$INSTALL_RANCHER" = true ]; then
    echo "kubectl get svc -n cattle-system                               # 查看 Rancher 服务"
    echo "kubectl logs -n cattle-system deployment/rancher -f            # 查看 Rancher 日志"
fi

echo "systemctl status kubelet                                       # kubelet 状态"
echo "systemctl status containerd                                    # containerd 状态"
echo "crictl ps                                                      # 容器列表"

echo ""
echo "⚠️  重要提醒："
echo "1. 控制台使用 HTTPS，浏览器会提示证书警告，点击'高级'->'继续访问'即可"

if [ "$INSTALL_K8S_DASHBOARD" = true ]; then
    echo "2. Kubernetes Dashboard 使用 Token 登录，安全性更高"
fi

if [ "$INSTALL_RANCHER" = true ]; then
    echo "3. Rancher 支持图形化用户管理，可以在界面直接添加用户"
    echo "4. Rancher 完全启动需要 5-10 分钟，请耐心等待"
fi

echo "5. 如果是云服务器，请确保防火墙开放以下端口："
echo "   - 6443 (Kubernetes API)"
echo "   - 30000-32767 (NodePort 服务)"

if [ "$INSTALL_K8S_DASHBOARD" = true ]; then
    echo "   - 30443 (Kubernetes Dashboard)"
fi

if [ "$INSTALL_RANCHER" = true ]; then
    echo "   - 30080 (Rancher HTTP)"
    echo "   - 30444 (Rancher HTTPS)"
fi

echo ""
echo "🌐 网络故障排除："
echo "如果网络有问题，可以运行以下命令："
echo "kubectl get pods -n kube-flannel                               # 检查 Flannel 状态"
echo "ls -la /run/flannel/                                           # 检查 Flannel 配置文件"
echo "kubectl logs -n kube-flannel -l app=flannel                    # 查看 Flannel 日志"
echo "kubectl describe pod [dashboard-pod-name] -n kubernetes-dashboard  # 查看 Dashboard Pod 详情"

echo ""
echo "✅ 脚本执行完毕！集群和控制台已准备就绪。"
