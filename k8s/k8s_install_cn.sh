#!/bin/bash
# Github: https://github.com/Jrohy/k8s-install  (原仓库)
# Modified for China Network Environment (Aliyun Mirrors)

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

# 用户传入的版本
k8s_version=""

# pkgs.k8s.io 使用的稳定大版本（例如 v1.34）
KUBERNETES_MINOR="v1.34"

# 国内源配置
ALIYUN_REGISTRY="registry.aliyuncs.com/google_containers"
# GitHub 文件加速代理 (如果有失效，可更换其他代理地址)
GH_PROXY="https://mirror.ghproxy.com/"

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
            echo "   --flannel                   use flannel network, and set this node as master"
            echo "   --calico                    use calico network, and set this node as master"
            echo "   --hostname [hostname]       set hostname"
            echo "   -v, --version [version]     install with Kubernetes minor repo, e.g. 1.34.0 -> v1.34"
            echo "   -h, --help                  show this help"
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
    echo "Kubernetes minor repo: $KUBERNETES_MINOR (Aliyun Mirror)"
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
            # 使用 docker-ce 的 repo 安装 containerd.io
            yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
            ${package_manager} install -y containerd.io
        else
            # Debian/Ubuntu 使用阿里云 docker-ce 源
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
              $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            ${package_manager} update -y
            ${package_manager} install -y containerd.io
        fi
    fi

    mkdir -p /etc/containerd
    containerd config default >/etc/containerd/config.toml 2>/dev/null

    # 设置 SystemdCgroup = true
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # 【国内优化】将 sandbox_image (registry.k8s.io/pause) 替换为 阿里云镜像
    sed -i "s|registry.k8s.io/pause|$ALIYUN_REGISTRY/pause|g" /etc/containerd/config.toml

    # 可选：配置 docker hub 镜像加速（如果需要拉取 docker.io 的镜像）
    # sed -i 's/config_path = ""/config_path = "\/etc\/containerd\/certs.d"/g' /etc/containerd/config.toml
    # mkdir -p /etc/containerd/certs.d/docker.io
    # cat > /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
    # server = "https://registry-1.docker.io"
    # [host."https://docker.m.daocloud.io"]
    #   capabilities = ["pull", "resolve"]
    # EOF

    systemctl enable containerd
    systemctl restart containerd
}

install_k8s_base() {
    # 使用阿里云 kubernetes-new 镜像源 (同步 pkgs.k8s.io)
    if [[ $package_manager == "apt-get" ]]; then
        # Debian / Ubuntu
        mkdir -p /etc/apt/keyrings
        curl -fsSL "https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/deb/Release.key" \
            | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/deb/ /" \
            > /etc/apt/sources.list.d/kubernetes.list

        ${package_manager} update -y
        ${package_manager} install -y kubelet kubeadm kubectl
    else
        # CentOS / Fedora
        cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBERNETES_MINOR}/rpm/repodata/repomd.xml.key
EOF
        # 暂时关闭 SELinux 验证 (阿里云源有时 Key 验证会有问题，可视情况开启)
        # setenforce 0
        ${package_manager} install -y kubelet kubeadm kubectl
    fi

    systemctl enable kubelet
    systemctl start kubelet

    # 命令行补全
    grep -q "kubectl completion bash" ~/.bashrc || echo "source <(kubectl completion bash)" >> ~/.bashrc
    grep -q "kubeadm completion bash" ~/.bashrc || echo "source <(kubeadm completion bash)" >> ~/.bashrc

    # 读取 client 版本
    k8s_client_ver=$(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | awk 'NR==1{print $2}')
    echo "kubectl client version: $(color_echo $green ${k8s_client_ver:-unknown})"
}

download_images() {
    color_echo $yellow "通过阿里云镜像源预拉取控制面镜像..."
    
    # 指定 --image-repository 使用阿里云
    images=($(kubeadm config images list --image-repository $ALIYUN_REGISTRY 2>/dev/null))
    
    if [[ ${#images[@]} -eq 0 ]]; then
        color_echo $red "获取镜像列表失败，请检查 kubeadm 安装或网络。"
        return
    fi

    for image in "${images[@]}"; do
        echo ""
        echo "checking image: $image"
        
        # 使用 crictl 或者 ctr (containerd 自带) 拉取
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
        else
             echo "  未找到 ctr，跳过手动拉取，依赖 kubeadm init 自动拉取。"
             break
        fi
    done
}

run_k8s(){
    if [[ $is_master -eq 1 ]]; then
        # kubeadm init 核心修改：增加 --image-repository 参数
        if [[ $network == "flannel" ]]; then
            run_command "kubeadm init --pod-network-cidr=10.244.0.0/16 --image-repository $ALIYUN_REGISTRY"
            run_command "mkdir -p \$HOME/.kube"
            run_command "cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
            run_command "chown \$(id -u):\$(id -g) \$HOME/.kube/config"
            
            # 使用代理地址下载 Flannel
            echo "Installing Flannel..."
            run_command "kubectl apply -f ${GH_PROXY}https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
            
        elif [[ $network == "calico" ]]; then
            run_command "kubeadm init --pod-network-cidr=192.168.0.0/16 --image-repository $ALIYUN_REGISTRY"
            run_command "mkdir -p \$HOME/.kube"
            run_command "cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
            run_command "chown \$(id -u):\$(id -g) \$HOME/.kube/config"
            
            # 使用代理地址下载 Calico
            echo "Installing Calico..."
            run_command "kubectl apply -f ${GH_PROXY}https://docs.projectcalico.org/manifests/calico.yaml"
        fi
    else
        echo ""
        echo "本节点作为 worker（未指定 --flannel/--calico），仅完成基础环境安装。"
        echo "请在 master 节点上执行："
        echo "  $(color_echo $green "kubeadm token create --print-join-command")"
        echo "然后在本机执行输出的 join 命令完成加入集群。"
    fi

    if command -v crictl >/dev/null 2>&1; then
        crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
        grep -q "crictl completion bash" ~/.bashrc || echo "source <(crictl completion bash)" >> ~/.bashrc
    fi

    color_echo $yellow "提示：kubectl / kubeadm / crictl 的命令行补全，需要重新登录 SSH 会话后生效。"
    if [[ $is_master -eq 1 ]]; then
        color_echo $green "Master 节点安装完成。请等待几分钟直到 Node 状态变为 Ready (kubectl get nodes)。"
    fi
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
