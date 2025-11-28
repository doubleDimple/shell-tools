# 1. master 安装 K8s（带 flannel）
bash k8s-install.sh --flannel -v 1.30.0

# 2. worker 安装 K8s
bash k8s-install.sh -v 1.30.0

# 3. master 生成 join 命令，并在 worker 上执行
kubeadm token create --print-join-command

# 4. master 安装 Rancher（Docker）
docker run -d --restart=unless-stopped \
  -p 80:80 -p 443:443 \
  --privileged \
  --name rancher \
  rancher/rancher:latest
