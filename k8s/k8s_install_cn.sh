#!/bin/bash
# doubleDimple
# Optimized for China Network: Auto Mirror & Proxy Fallback

####### color code ########
red="31m"
green="32m"
yellow="33m"
blue="36m"
fuchsia="35m"

is_master=0
network=""
k8s_version=""
KUBERNETES_MINOR="v1.34"

# --- 国内环境配置 ---
ALIYUN_REGISTRY="registry.aliyuncs.com/google_containers"
GH_PROXY="https://ghproxy.net/"
# 镜像加速域名
MIRROR_DOMAIN="docker.m.daocloud.io"

color_echo(){
    echo -e "\033[$1${*:2}\033[0m"
}

run_command(){
    echo ""
    local command=$1
    echo -e "\033[32m$command\033[0m"
    eval "$command"
}

set_hostname(){
    local hostname=$1
    if [[ $hostname =~ '_' ]];then
        color_echo $yellow "hostname 不能包含 '_'，自动替换为 '-' ..."
        hostname=$(echo "$hostname" | sed 's/_/-/g')
    fi
    echo "set hostname: $(color_echo $blue $hostname)"
    grep -q "127.0.0.1 $hostname" /etc/hosts || echo "127.0.0.1 $hostname" >> /etc/hosts
    run_command "hostnamectl --static set-hostname $hostname"
}

# --- 核心改进：带镜像替换的 CNI 安装函数 ---
apply_cni_with_fallback() {
    local url=$1
    local filename="cni_plugin_temp.yaml"
    
    echo ""
    color_echo $yellow "正在下载并优化网络插件配置..."
    
    # 1. 下载 YAML (尝试直连 -> 代理)
    if ! curl -sSL --connect-timeout 5 -o $filename "$url"; then
        color_echo $blue "直连超时，尝试通过代理下载..."
        curl -sSL -o $filename "${GH_PROXY}${url}"
    fi

    if [[ ! -f $filename ]]; then
        color_echo $red "❌ 插件文件下载失败，请检查网络！"
        return 1
    fi

    # 2. 核心：替换镜像源，防止 Pod 卡在拉取阶段
    echo "正在自动转换镜像源为国内加速地址..."
    # 替换 Flannel 镜像
    sed -i "s|ghcr.io/flannel-io/flannel|${MIRROR_DOMAIN}/flannel/flannel|g" $filename
    # 替换 Calico 镜像 (涵盖 quay.io 和 docker.io)
    sed -i "s|quay.io/calico/|${MIRROR_DOMAIN}/calico/|g" $filename
    sed -i "s|docker.io/calico/|${MIRROR_DOMAIN}/calico/|g" $filename

    # 3. 准备 CNI 基础目录
    mkdir -p /opt/cni/bin

    # 4. 应用
    if kubectl apply -f $filename; then
        color_echo $green "✅ 网络插件部署成功 (已应用加速配置)！"
        rm -f $filename
    else
        color_echo $red "❌ 插件应用失败。"
        return 1
    fi
}

####### get params #########
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname) set_hostname "$2"; shift ;;
        -v|--version)
            k8s_version="${2#v}"
            if [[ "$k8s_version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
                KUBERNETES_MINOR="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
            fi
            shift ;;
        --flannel) network="flannel"; is_master=1 ;;
        --calico) network="calico"; is_master=1 ;;
        -h|--help)
            echo "Usage: $0 [--flannel|--calico] [--hostname name] [-v version]"
            exit 0 ;;
    esac
    shift
done

check_sys() {
    if [[ $(id -u) != "0" ]]; then color_echo ${red} "Error: 必须 root 执行"; exit 1; fi
    if [[ "$(grep -c '^processor' /proc/cpuinfo)" == "1" && $is_master == 1 ]]; then
        color_echo ${red} "Master 核心需 >= 2"; exit 1
    fi
    if grep -qi Ubuntu /etc/issue; then os='Ubuntu'; package_manager='apt-get'
    elif grep -qi CentOS /etc/redhat-release; then os='CentOS'; package_manager='yum'
    else os='Debian'; package_manager='apt-get'; fi
}

install_dependent(){
    ${package_manager} update -y
    if [[ ${os} == 'CentOS' ]]; then ${package_manager} install -y bash-completion yum-utils curl
    else ${package_manager} install -y bash-completion apt-transport-https curl gpg; fi
}

prepare_sysctl_and_swap() {
    cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
    modprobe br_netfilter && sysctl --system
    swapoff -a && sed -i 's/^\(.*swap.*\)$/#\1/g' /etc/fstab
    if [ -f /etc/selinux/config ]; then sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config; setenforce 0 || true; fi
}

install_containerd() {
    if ! command -v containerd >/dev/null; then
        if [[ ${os} == 'CentOS' ]]; then
            yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            ${package_manager} install -y containerd.io
        else
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
            ${package_manager} update -y && ${package_manager} install -y containerd.io
        fi
    fi
    mkdir -p /etc/containerd
    containerd config default >/etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sed -i "s|registry.k8s.io/pause|$ALIYUN_REGISTRY/pause|g" /etc/containerd/config.toml
    systemctl enable --now containerd
}

install_k8s_base() {
    if [[ $package_manager == "apt-get" ]]; then
        curl -fsSL "https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -y && apt-get install -y kubelet kubeadm kubectl
    else
        cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/rpm/repodata/repomd.xml.key
EOF
        yum install -y kubelet kubeadm kubectl
    fi
    systemctl enable --now kubelet
}

run_k8s(){
    if [[ $is_master -eq 1 ]]; then
        # Init with Aliyun Registry
        if [[ $network == "flannel" ]]; then
            kubeadm init --pod-network-cidr=10.244.0.0/16 --image-repository $ALIYUN_REGISTRY
        else
            kubeadm init --pod-network-cidr=192.168.0.0/16 --image-repository $ALIYUN_REGISTRY
        fi

        mkdir -p $HOME/.kube && cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        chown $(id -u):$(id -g) $HOME/.kube/config
        
        # Apply CNI with Mirror
        if [[ $network == "flannel" ]]; then
            apply_cni_with_fallback "https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
        else
            apply_cni_with_fallback "https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml"
        fi

        # Untaint Master
        kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
    fi
}

main() {
    check_sys
    prepare_sysctl_and_swap
    install_dependent
    install_containerd
    install_k8s_base
    run_k8s
}

main
