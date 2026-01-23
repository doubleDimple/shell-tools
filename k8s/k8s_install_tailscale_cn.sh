#!/bin/bash
# Github: https://github.com/Jrohy/k8s-install
# Tailscale Edition: Supports Multi-Cloud / Cross-Vendor Interconnection

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

# --- 国内环境与加速配置 ---
ALIYUN_REGISTRY="registry.aliyuncs.com/google_containers"
GH_PROXY="https://ghproxy.net/"
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

# --- 适配 Tailscale 的 CNI 安装函数 ---
apply_cni_with_fallback() {
    local url=$1
    local filename="cni_plugin_temp.yaml"
    
    echo ""
    color_echo $yellow "正在配置网络插件 (适配 Tailscale)..."
    
    if ! curl -sSL --connect-timeout 5 -o $filename "$url"; then
        curl -sSL -o $filename "${GH_PROXY}${url}"
    fi

    if [[ ! -f $filename ]]; then
        color_echo $red "❌ 插件文件下载失败！"
        return 1
    fi

    # 1. 镜像替换 (加速)
    sed -i "s|ghcr.io/flannel-io/flannel|${MIRROR_DOMAIN}/flannel/flannel|g" $filename
    sed -i "s|quay.io/calico/|${MIRROR_DOMAIN}/calico/|g" $filename
    sed -i "s|docker.io/calico/|${MIRROR_DOMAIN}/calico/|g" $filename

    # 2. 关键：如果是 Flannel，强制指定使用 tailscale0 网卡
    if [[ $network == "flannel" ]]; then
        # 在 args 列表中 kube-subnet-mgr 之后插入 --iface=tailscale0
        sed -i '/- --kube-subnet-mgr/a \        - --iface=tailscale0' $filename
        color_echo $blue "已锁定 Flannel 使用 tailscale0 网卡"
    fi

    mkdir -p /opt/cni/bin

    if kubectl apply -f $filename; then
        color_echo $green "✅ 网络插件应用成功！"
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
            echo "Usage: $0 [--flannel|--calico] [--hostname name]"
            exit 0 ;;
    esac
    shift
done

check_sys() {
    if [[ $(id -u) != "0" ]]; then color_echo ${red} "Error: 必须 root 执行"; exit 1; fi
    # 检查 Tailscale
    TS_IP=$(ip -4 addr show tailscale0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [[ -z "$TS_IP" ]]; then
        color_echo ${red} "Error: 未找到 tailscale0 网卡。请先安装并启动 Tailscale！"
        exit 1
    fi
    color_echo $green "检测到 Tailscale 节点 IP: $TS_IP"
    
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
    
    # --- 核心：配置 Kubelet 绑定 Tailscale IP ---
    echo "KUBELET_EXTRA_ARGS=--node-ip=$TS_IP" > /etc/default/kubelet
    systemctl enable --now kubelet
    systemctl restart kubelet
}

run_k8s(){
    if [[ $is_master -eq 1 ]]; then
        # 增加 --apiserver-advertise-address 强制 API Server 广播 Tailscale 地址
        if [[ $network == "flannel" ]]; then
            kubeadm init --pod-network-cidr=10.244.0.0/16 --image-repository $ALIYUN_REGISTRY --apiserver-advertise-address=$TS_IP
        else
            kubeadm init --pod-network-cidr=192.168.0.0/16 --image-repository $ALIYUN_REGISTRY --apiserver-advertise-address=$TS_IP
        fi

        mkdir -p $HOME/.kube && cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        chown $(id -u):$(id -g) $HOME/.kube/config
        
        # 应用 CNI
        if [[ $network == "flannel" ]]; then
            apply_cni_with_fallback "https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
        else
            apply_cni_with_fallback "https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml"
        fi

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
    
    if [[ $is_master -eq 1 ]]; then
        color_echo $green "✅ Master 节点已通过 Tailscale 网络安装完成！"
        color_echo $blue "生成的 join 命令将使用 IP: $TS_IP"
    else
        color_echo $green "✅ 节点基础环境准备完成！"
        color_echo $yellow "请确保此节点已连接 Tailscale，然后执行 Master 提供的 join 命令。"
    fi
}

main
