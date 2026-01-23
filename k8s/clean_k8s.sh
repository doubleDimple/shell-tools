#!/bin/bash
####### color code ########
red="31m"
green="32m"
yellow="33m"

color_echo(){
    echo -e "\033[$1${*:2}\033[0m"
}

# 检查是否为 root
if [[ $(id -u) != "0" ]]; then
    color_echo ${red} "Error: 必须使用 root 执行此脚本"
    exit 1
fi

echo "=========================================================="
color_echo $yellow "警告: 此脚本将彻底删除本机 Kubernetes 集群和相关数据！"
color_echo $yellow "Warning: This script will remove the Kubernetes cluster completely!"
echo "=========================================================="
read -p "是否继续? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "已取消。"
    exit 0
fi

# 1. 使用 kubeadm 重置节点
if command -v kubeadm >/dev/null 2>&1; then
    color_echo $green "正在执行 kubeadm reset..."
    kubeadm reset -f
else
    color_echo $yellow "未找到 kubeadm，跳过 reset 步骤。"
fi

# 2. 停止服务
color_echo $green "停止相关服务..."
systemctl stop kubelet
systemctl stop containerd
systemctl stop docker 2>/dev/null

# 3. 清理残留网络接口 (CNI)
color_echo $green "清理 CNI 网络接口..."
ip link delete cni0 2>/dev/null
ip link delete flannel.1 2>/dev/null
ip link delete weave 2>/dev/null
ip link delete kube-ipvs0 2>/dev/null
# 清理 Calico 相关网卡
for dev in $(ip link | awk -F: '/cali/ {print $2}'); do ip link del $dev; done

# 4. 清理 iptables 规则
color_echo $green "清理 iptables 规则..."
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X

# 5. 清理 ipvs (如果启用了 ipvs 模式)
if command -v ipvsadm >/dev/null 2>&1; then
    color_echo $green "清理 IPVS 表..."
    ipvsadm -C
fi

# 6. 删除相关文件和目录 (这是最重要的一步)
color_echo $green "删除 Kubernetes 相关文件和目录..."
rm -rf /etc/kubernetes/
rm -rf /var/lib/kubelet/
rm -rf /var/lib/etcd/
rm -rf /var/lib/cni/
rm -rf /etc/cni/
rm -rf /opt/cni/
rm -rf $HOME/.kube
rm -rf /var/log/pods/
rm -rf /var/log/containers/

# 7. 卸载软件包 (可选，如果你想保留 docker/containerd 可以注释掉这一块)
color_echo $green "卸载 Kubernetes 软件包..."
if [[ -e /etc/redhat-release ]]; then
    yum remove -y kubelet kubeadm kubectl
elif grep -qi Debian /etc/issue || grep -qi Ubuntu /etc/issue; then
    apt-get purge -y kubelet kubeadm kubectl
    apt-get autoremove -y
fi

# 8. 重启 Containerd (为下次安装做准备)
color_echo $green "重启 Container Runtime..."
systemctl restart containerd
# 如果有 docker 也重启一下
systemctl restart docker 2>/dev/null

color_echo $green "清理完成！现在可以重新运行安装脚本了。"
