#!/bin/bash
# Kubernetes + Dashboard 完全重装脚本 - 支持 Ubuntu/Debian/CentOS/RHEL
set -e

echo "🚀 Kubernetes + Dashboard 完全重装脚本 v5.0"
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
    echo "🧹 [1/12] 强制清理所有 Kubernetes 组件..."
    
    # 停止所有相关服务
    echo "停止相关服务..."
    systemctl stop kubelet 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
    systemctl stop docker 2>/dev/null || true
    systemctl stop cri-docker 2>/dev/null || true
    
    # 强制杀死相关进程
    echo "杀死相关进程..."
    pkill -9 -f kubelet 2>/dev/null || true
    pkill -9 -f kube-proxy 2>/dev/null || true
    pkill -9 -f kube-apiserver 2>/dev/null || true
    pkill -9 -f kube-controller 2>/dev/null || true
    pkill -9 -f kube-scheduler 2>/dev/null || true
    pkill -9 -f etcd 2>/dev/null || true
    pkill -9 -f containerd 2>/dev/null || true
    pkill -9 -f dockerd 2>/dev/null || true
    
    # 等待进程完全停止
    sleep 5
    
    # 重置 kubeadm（如果存在）
    echo "重置 kubeadm..."
    kubeadm reset -f 2>/dev/null || true
    
    # 卸载软件包
    echo "卸载软件包..."
    case $PKG_MANAGER in
        apt)
            apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
            apt remove --purge -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
            apt remove --purge -y docker-ce docker-ce-cli containerd.io containerd 2>/dev/null || true
            apt remove --purge -y docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            apt remove --purge -y cri-tools 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
            apt autoclean 2>/dev/null || true
            ;;
        yum|dnf)
            $PKG_MANAGER remove -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
            $PKG_MANAGER remove -y docker-ce docker-ce-cli containerd.io containerd 2>/dev/null || true
            $PKG_MANAGER remove -y cri-tools 2>/dev/null || true
            $PKG_MANAGER autoremove -y 2>/dev/null || true
            ;;
    esac
    
    # 清理文件和目录
    echo "清理文件和目录..."
    rm -rf ~/.kube
    rm -rf /etc/kubernetes
    rm -rf /var/lib/kubelet
    rm -rf /var/lib/etcd
    rm -rf /etc/docker
    rm -rf /etc/containerd
    rm -rf /var/lib/containerd
    rm -rf /opt/containerd
    rm -rf /var/lib/docker
    rm -rf /opt/cni
    rm -rf /etc/cni
    rm -rf /var/lib/cni
    rm -rf /run/flannel
    rm -rf /etc/systemd/system/kubelet.service.d
    rm -rf /etc/systemd/system/docker.service.d
    rm -rf /lib/systemd/system/kubelet.service
    rm -rf /etc/crictl.yaml
    
    # 清理仓库配置
    echo "清理仓库配置..."
    rm -rf /etc/apt/sources.list.d/kubernetes*.list
    rm -rf /etc/apt/sources.list.d/docker*.list
    rm -rf /etc/yum.repos.d/kubernetes.repo
    rm -rf /etc/yum.repos.d/docker*.repo
    rm -rf /etc/apt/keyrings/kubernetes*.gpg
    rm -rf /etc/apt/keyrings/docker*.gpg
    
    # 清理网络接口
    echo "清理网络接口..."
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    ip link delete docker0 2>/dev/null || true
    ip link delete kube-bridge 2>/dev/null || true
    
    # 清理 iptables 规则
    echo "清理 iptables 规则..."
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true
    iptables -t filter -F 2>/dev/null || true
    iptables -t filter -X 2>/dev/null || true
    
    # 清理 systemd 服务
    echo "清理 systemd 服务..."
    systemctl daemon-reload
    systemctl reset-failed
    
    # 强制卸载残留的挂载点
    echo "清理挂载点..."
    umount /var/lib/kubelet/pods/*/volumes/kubernetes.io~secret/* 2>/dev/null || true
    umount /var/lib/kubelet/pods/*/volumes/kubernetes.io~configmap/* 2>/dev/null || true
    umount /var/lib/kubelet/* 2>/dev/null || true
    
    # 检查并杀死占用关键端口的进程
    echo "检查关键端口..."
    for port in 6443 10250 10251 10252 2379 2380; do
        PID=$(lsof -ti :$port 2>/dev/null || true)
        if [ -n "$PID" ]; then
            echo "杀死占用端口 $port 的进程 $PID"
            kill -9 $PID 2>/dev/null || true
        fi
    done
    
    echo "✅ 强制清理完成"
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

# 开始安装
detect_os

echo ""
echo "📋 系统信息："
echo "操作系统: $OS $OS_VERSION"
echo "包管理器: $PKG_MANAGER"
if [ -n "$CODENAME" ]; then
    echo "代码名: $CODENAME"
fi

# 强制清理
force_cleanup

echo ""
echo "📦 [2/12] 更新系统并安装依赖..."
update_system
install_basic_packages

echo ""
echo "🔧 [3/12] 配置内核参数..."
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
echo "🐳 [4/12] 安装 containerd..."
install_containerd

echo ""
echo "🔧 [5/12] 配置 containerd..."

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
echo "☸️  [6/12] 安装 Kubernetes 1.29..."
install_kubernetes

# 启动 kubelet
systemctl enable kubelet

echo ""
echo "🔧 [7/12] 配置 CRI 接口..."

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
echo "🛠️ [8/12] 安装 Helm..."
install_helm

echo ""
echo "🔍 [9/12] 验证安装..."

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
echo "🎯 [10/12] 初始化 Kubernetes 集群..."

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
echo "🌐 [11/12] 安装网络插件..."

# 安装 Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 等待节点就绪
echo "等待节点就绪..."
kubectl wait --for=condition=Ready node --all --timeout=300s || true

echo ""
echo "📊 [12/12] 安装 Kubernetes Dashboard..."

# 安装 Kubernetes Dashboard
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
echo "创建管理员用户..."
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
echo "获取访问令牌..."
TOKEN=$(kubectl get secret admin-user-token -n kubernetes-dashboard -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || echo "Token生成失败，请手动运行：kubectl -n kubernetes-dashboard create token admin-user")

echo ""
echo "🎉 Kubernetes + Dashboard 安装完成！"
echo "================================================================"

# 显示集群状态
echo "集群节点状态:"
kubectl get nodes -o wide

echo ""
echo "系统 Pods 状态:"
kubectl get pods -n kube-system

echo ""
echo "Dashboard 相关 Pods:"
kubectl get pods -n kubernetes-dashboard

echo ""
echo "================================================================"
echo "🔑 Worker 节点加入命令："
kubeadm token create --print-join-command
echo "================================================================"

echo ""
echo "📊 Kubernetes Dashboard 控制台："
echo "地址: https://$LOCAL_IP:30443"
echo "登录方式: Token"
echo "访问令牌:"
echo "$TOKEN"

echo ""
echo "🔍 监控命令："
echo "kubectl get pods --all-namespaces                              # 查看所有 Pod"
echo "kubectl get svc -n kubernetes-dashboard                        # 查看 Dashboard 服务"
echo "kubectl -n kubernetes-dashboard create token admin-user        # 重新生成访问令牌"
echo "kubectl get secret admin-user-token -n kubernetes-dashboard -o jsonpath='{.data.token}' | base64 -d  # 获取永久令牌"
echo "systemctl status kubelet                                       # kubelet 状态"
echo "systemctl status containerd                                    # containerd 状态"
echo "crictl ps                                                      # 容器列表"

echo ""
echo "⚠️  重要提醒："
echo "1. Dashboard 使用 HTTPS，浏览器会提示证书警告，点击'高级'->'继续访问'即可"
echo "2. 登录时选择 'Token' 方式，粘贴上面显示的访问令牌"
echo "3. 如果是云服务器，请确保防火墙开放以下端口："
echo "   - 6443 (Kubernetes API)"
echo "   - 30000-32767 (NodePort 服务)"
echo "   - 30443 (Kubernetes Dashboard)"
echo "4. 如需重新生成令牌，运行："
echo "   kubectl -n kubernetes-dashboard create token admin-user"

echo ""
echo "✅ 脚本执行完毕！Kubernetes 集群和 Dashboard 已准备就绪。"
