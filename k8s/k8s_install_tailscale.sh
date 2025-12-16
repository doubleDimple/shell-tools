#!/bin/bash
# Github: https://github.com/Jrohy/k8s-install  (原仓库)

####### color code ########
red="31m"
green="32m"
yellow="33m"
blue="36m"
fuchsia="35m"

# 是否是 master 节点（根据是否指定网络插件决定）
is_master=0

# flannel / calico
network=""

# 用户传入的版本（例如 1.34.0），仅用于选择 pkgs.k8s.io 大版本
k8s_version=""

# pkgs.k8s.io 使用的稳定大版本（例如 v1.34）
KUBERNETES_MINOR="v1.34"

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
            echo "将使用 Kubernetes 稳定仓库: $(color_echo $green $KUBERNETES_MINOR)"
            shift
            ;;
        --flannel)
            echo "use flannel network, and set this node as master"
            network="flannel"
            is_master=1
            ;;
        --calico)
            echo "use calico network, and set this node as master"
            network="calico"
            is_master=1
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "   --flannel                    use flannel network, and set this node as master"
            echo "   --calico                     use calico network, and set this node as master"
            echo "   --hostname [hostname]        set hostname"
            echo "   -v, --version [version]      install with Kubernetes minor repo, e.g. 1.34.0 -> v1.34"
            echo "   -h, --help                   show this help"
            echo ""
            exit 0
            ;;
        *)
            # unknown option, ignore
            ;;
    esac
    shift
done
#############################

check_sys() {
    # root
    if [[ $(id -u) != "0" ]]; then
        color_echo ${red} "Error: 必须使用 root 执行本脚本"
        exit 1
    fi

    # CPU number
    if [[ "$(grep -c '^processor' /proc/cpuinfo)" == "1" && $is_master == 1 ]]; then
        color_echo ${red} "master 节点 CPU 核心数必须 >= 2"
        exit 1
    fi

    # OS detect
    if [[ -e /etc/redhat-release ]]; then
        if grep -qi Fedora /etc/redhat-release; then
            os='Fedora'
            package_manager='dnf'
        else
            os='CentOS'
            package_manager='yum'
        fi
    elif grep -qi Debian /etc/issue; then
        os='Debian'
        package_manager='apt-get'
    elif grep -qi Ubuntu /etc/issue; then
        os='Ubuntu'
        package_manager='apt-get'
    else
        color_echo ${red} "暂不支持的系统，请使用 CentOS / Debian / Ubuntu / Fedora"
        exit 1
    fi

    # 修正 hostname 中的 '_'
    if [[ "$(cat /etc/hostname)" =~ '_' ]]; then
        set_hostname "$(cat /etc/hostname)"
    fi

    echo "OS: $os, Package manager: $package_manager"
    echo "Kubernetes minor repo: $KUBERNETES_MINOR"
}

install_dependent(){
    if [[ ${os} == 'CentOS' || ${os} == 'Fedora' ]]; then
        ${package_manager} install -y bash-completion yum-utils curl
    else
        ${package_manager} update -y
        ${package_manager} install -y bash-completion apt-transport-https curl gpg
    fi
}

prepare_sysctl_and_swap() {
    # 开启网桥转发
    cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
    modprobe br_netfilter || true
    sysctl --system

    # 禁用 SELinux（仅 CentOS / Fedora）
    if [[ -s /etc/selinux/config ]] && grep -q 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0 || true
    fi

    # 关闭 swap
    swapoff -a
    sed -i 's/^\(.*swap.*\)$/#\1/g' /etc/fstab
}

install_containerd() {
    if ! command -v containerd >/dev/null 2>&1; then
        color_echo $yellow "containerd 未安装，开始安装 containerd..."
        if [[ ${os} == 'CentOS' || ${os} == 'Fedora' ]]; then
            ${package_manager} install -y containerd
        else
            ${package_manager} update -y
            ${package_manager} install -y containerd
        fi
    fi

    mkdir -p /etc/containerd
    containerd config default >/etc/containerd/config.toml 2>/dev/null

    # 设置 SystemdCgroup = true
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

    systemctl enable containerd
    systemctl restart containerd
}

install_k8s_base() {
    if [[ $package_manager == "apt-get" ]]; then
        # Debian / Ubuntu: 使用 pkgs.k8s.io
        mkdir -p /etc/apt/keyrings
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
            | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /" \
            > /etc/apt/sources.list.d/kubernetes.list

        ${package_manager} update -y
        ${package_manager} install -y kubelet kubeadm kubectl
    else
        # CentOS / Fedora: 使用 pkgs.k8s.io
        cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/rpm/repodata/repomd.xml.key
EOF
        ${package_manager} install -y kubelet kubeadm kubectl
    fi

    systemctl enable kubelet
    systemctl start kubelet

    # 命令行补全
    grep -q "kubectl completion bash" ~/.bashrc || echo "source <(kubectl completion bash)" >> ~/.bashrc
    grep -q "kubeadm completion bash" ~/.bashrc || echo "source <(kubeadm completion bash)" >> ~/.bashrc

    # 读取 client 版本（用于日志输出）
    k8s_client_ver=$(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | awk 'NR==1{print $2}')
    echo "kubectl client version: $(color_echo $green ${k8s_client_ver:-unknown})"
}

download_images() {
    color_echo $yellow "通过 'kubeadm config images list' 预拉取控制面镜像..."

    images=($(kubeadm config images list 2>/dev/null))
    if [[ ${#images[@]} -eq 0 ]]; then
        color_echo $red "kubeadm config images list 未返回镜像，可能是 kubeadm 未正确安装或版本不匹配，跳过预拉取。"
        return
    fi

    for image in "${images[@]}"; do
        echo ""
        echo "checking image: $image"

        if command -v ctr >/dev/null 2>&1; then
            if ctr -n k8s.io i ls -q | grep -qw "$image"; then
                echo "  already exists: $(color_echo $green $image)"
                continue
            fi
            echo "  pulling with containerd (ctr)..."
            if ctr -n k8s.io i pull "$image"; then
                echo "  pulled: $(color_echo $blue $image)"
            else
                echo "  failed: $(color_echo $red $image)"
            fi
        elif command -v docker >/dev/null 2>&1; then
            if docker images "$image" | awk 'NR>1{found=1} END{exit !found}'; then
                echo "  already exists: $(color_echo $green $image)"
                continue
            fi
            echo "  pulling with docker..."
            if docker pull "$image"; then
                echo "  pulled: $(color_echo $blue $image)"
            else
                echo "  failed: $(color_echo $red $image)"
            fi
        else
            echo "  未找到 ctr 或 docker，无法预拉取镜像。"
            break
        fi
    done
}

run_k8s(){
    # 获取 Tailscale IP (新增逻辑)
    local ts_ip=""
    if command -v tailscale >/dev/null 2>&1; then
        ts_ip=$(tailscale ip -4)
        echo "检测到 Tailscale IP: $ts_ip，将加入 API Server 证书..."
    fi

    if [[ $is_master -eq 1 ]]; then
        # kubeadm init
        if [[ $network == "flannel" ]]; then
            # 修复 1：把 Tailscale IP 加入证书
            run_command "kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-cert-extra-sans=${ts_ip:-}"
            
            run_command "mkdir -p \$HOME/.kube"
            run_command "cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
            run_command "chown \$(id -u):\$(id -g) \$HOME/.kube/config"
            
            # 修复 2：下载 Flannel 配置并修改 MTU 为 1200
            echo "正在修复 Flannel MTU 以适配 Tailscale..."
            curl -sL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml > kube-flannel.yml
            sed -i 's/"Network": "10.244.0.0\/16",/"Network": "10.244.0.0\/16",\n      "Backend": {\n        "Type": "vxlan",\n        "MTU": 1200\n      },/g' kube-flannel.yml
            
            run_command "kubectl apply -f kube-flannel.yml"
            rm -f kube-flannel.yml
            
        elif [[ $network == "calico" ]]; then
            # Calico 依然保持原样 (不推荐在 Tailscale 下用这个)
            run_command "kubeadm init --pod-network-cidr=192.168.0.0/16"
            run_command "mkdir -p \$HOME/.kube"
            run_command "cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
            run_command "chown \$(id -u):\$(id -g) \$HOME/.kube/config"
            run_command "kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml"
        fi
    else
        echo ""
        echo "本节点作为 worker。"
        echo "请在 master 节点上执行："
        echo "  $(color_echo $green "kubeadm token create --print-join-command")"
    fi

    if command -v crictl >/dev/null 2>&1; then
        crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
        grep -q "crictl completion bash" ~/.bashrc || echo "source <(crictl completion bash)" >> ~/.bashrc
    fi

    color_echo $yellow "提示：kubectl / kubeadm / crictl 的命令行补全，需要重新登录 SSH 会话后生效。"
}

main() {
    check_sys
    prepare_sysctl_and_swap
    install_dependent
    install_containerd
    install_k8s_base
    download_images
    run_k8s
}

main
