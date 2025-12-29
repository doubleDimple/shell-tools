#!/bin/bash
# Modified for China VPS - Base on Jrohy/k8s-install

####### color code ########
red="31m"
green="32m"
yellow="33m"
blue="36m"
fuchsia="35m"

# 是否是 master 节点
is_master=0
# flannel / calico
network=""
# 默认版本
KUBERNETES_MINOR="v1.31"

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

####### get params #########
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)
            set_hostname "$2"
            shift
            ;;
        -v|--version)
            k8s_version="${2#v}"
            if [[ "$k8s_version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
                KUBERNETES_MINOR="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
            fi
            shift
            ;;
        --flannel)
            echo "使用 Flannel 网络，设为 Master 节点"
            network="flannel"
            is_master=1
            ;;
        --calico)
            echo "使用 Calico 网络，设为 Master 节点"
            network="calico"
            is_master=1
            ;;
        -h|--help)
            echo "使用说明:"
            echo "  --flannel              安装为 Master 并使用 Flannel"
            echo "  --calico               安装为 Master 并使用 Calico"
            echo "  --hostname [name]      设置主机名"
            echo "  -v, --version [ver]    指定版本 (默认 v1.31)"
            exit 0
            ;;
    esac
    shift
done

check_sys() {
    if [[ $(id -u) != "0" ]]; then
        color_echo ${red} "Error: 必须使用 root 执行"
        exit 1
    fi

    if [[ "$(grep -c '^processor' /proc/cpuinfo)" == "1" && $is_master == 1 ]]; then
        color_echo ${red} "Master 节点 CPU 必须 >= 2核"
        exit 1
    fi

    if [[ -e /etc/redhat-release ]]; then
        os='CentOS'; package_manager='yum'
    elif grep -qi "Ubuntu" /etc/os-release; then
        os='Ubuntu'; package_manager='apt-get'
    elif grep -qi "Debian" /etc/os-release; then
        os='Debian'; package_manager='apt-get'
    else
        color_echo ${red} "仅支持 CentOS/Ubuntu/Debian"
        exit 1
    fi
    echo "操作系统: $os, 仓库大版本: $KUBERNETES_MINOR"
}

prepare_sys() {
    color_echo $blue ">>> 正在优化系统内核参数及关闭 Swap..."
    swapoff -a
    sed -i '/swap/s/^/#/' /etc/fstab
    
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
    modprobe br_netfilter || true
    sysctl --system

    if [[ $os == 'CentOS' ]]; then
        setenforce 0 || true
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    fi
}

install_containerd() {
    color_echo $blue ">>> 正在安装 Containerd (国内源)..."
    if [[ $package_manager == "apt-get" ]]; then
        apt-get update && apt-get install -y containerd
    else
        yum install -y yum-utils
        yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
        yum install -y containerd.io
    fi

    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml >/dev/null
    
    # 关键修改：国内 pause 镜像及 SystemdCgroup
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sed -i 's|registry.k8s.io/pause:3.6|registry.aliyuncs.com/google_containers/pause:3.10|g' /etc/containerd/config.toml
    sed -i 's|registry.k8s.io/pause:3.8|registry.aliyuncs.com/google_containers/pause:3.10|g' /etc/containerd/config.toml
    
    systemctl restart containerd
    systemctl enable containerd
}

install_k8s_base() {
    color_echo $blue ">>> 正在安装 K8s 组件 (阿里云镜像源)..."
    if [[ $package_manager == "apt-get" ]]; then
        apt-get update && apt-get install -y apt-transport-https curl
        curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
        apt-get update
        apt-get install -y kubelet kubeadm kubectl
    else
        cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/rpm/repodata/repomd.xml.key
EOF
        yum install -y kubelet kubeadm kubectl
    fi
    systemctl enable kubelet && systemctl start kubelet
}

run_k8s() {
    if [[ $is_master -eq 1 ]]; then
        color_echo $green ">>> 正在初始化 Master 节点 (使用阿里云容器仓库)..."
        # 指定国内镜像仓库地址
        local init_cmd="kubeadm init --image-repository registry.aliyuncs.com/google_containers"
        
        if [[ $network == "flannel" ]]; then
            eval "$init_cmd --pod-network-cidr=10.244.0.0/16"
            mkdir -p $HOME/.kube
            cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
            chown $(id -u):$(id -g) $HOME/.kube/config
            # 国内环境下载 flannel 配置文件可能较慢，建议手动下载或尝试：
            kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml || color_echo $yellow "Flannel YAML 下载失败，请手动 apply"
        elif [[ $network == "calico" ]]; then
            eval "$init_cmd --pod-network-cidr=192.168.0.0/16"
            mkdir -p $HOME/.kube
            cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
            chown $(id -u):$(id -g) $HOME/.kube/config
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml || color_echo $yellow "Calico YAML 下载失败"
        fi
    else
        color_echo $fuchsia "================================================="
        color_echo $green "本节点环境已准备完毕！(Worker 模式)"
        color_echo $green "请在 Master 节点执行: kubeadm token create --print-join-command"
        color_echo $green "然后将得到的命令粘贴到此处执行即可。"
        color_echo $fuchsia "================================================="
    fi
    
    # 配置 crictl
    if command -v crictl >/dev/null 2>&1; then
        crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
    fi
}

main() {
    check_sys
    prepare_sys
    install_containerd
    install_k8s_base
    run_k8s
}

main
