# 🚀 KubeSphere 多节点安装指南

本项目提供了一套 **开源、免费、企业可用** 的 **Kubernetes + KubeSphere** 多节点安装方案。  
安装完成后，你将获得一个带 **可视化面板** 的企业级 K8s 集群。

---

## 📋 环境要求

| 角色     | 最低配置                              |
| -------- | ------------------------------------- |
| Master   | 2 核 CPU / 4 GB RAM / 40 GB 磁盘      |
| Worker   | 2 核 CPU / 2 GB RAM / 30 GB 磁盘      |
| 网络     | 所有节点互通，关闭 swap               |
| 系统     | Ubuntu 20.04+/22.04 或 CentOS 7.6+    |

---

## 🔧 安装步骤

### 1️⃣ Master 节点

在 **Master 节点** 上执行：

```bash
chmod +x install-master.sh
./install-master.sh

2️⃣ 保存 Join 命令

脚本执行完成后会打印出类似命令，请保存（Worker 节点加入时使用）：

kubeadm join 192.168.0.10:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:xxxxxxxx

3️⃣ Worker 节点

在每台 Worker 节点 上执行：

chmod +x install-worker.sh
./install-worker.sh

4️⃣ 节点加入集群

在 Worker 节点 执行 Master 节点生成的 join 命令，例如：

kubeadm join 192.168.0.10:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:xxxxxxxx

5️⃣ 验证集群状态

在 Master 节点 执行：

kubectl get nodes


你应该看到类似输出：

NAME               STATUS   ROLES           AGE     VERSION
master-node        Ready    control-plane   15m     v1.29.x
worker-node-1      Ready    <none>          5m      v1.29.x
worker-node-2      Ready    <none>          3m      v1.29.x

6️⃣ 访问 KubeSphere 控制台

查看控制台服务：

kubectl get svc -n kubesphere-system


找到 ks-console：

NAME          TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
ks-console    NodePort   10.96.34.5      <none>        30880:30880/TCP  10m

7️⃣ 登录控制台

在浏览器访问：

http://<Master 节点 IP>:30880


默认账号密码：

用户名：admin
密码：P@88w0rd

✅ 总结
项目	内容
部署方式	kubeadm + flannel + KubeSphere
多节点支持	✅ Master + 多个 Worker
面板地址	http://Master_IP:30880
默认账号	admin
默认密码	P@88w0rd
权限控制	支持多租户、RBAC、安全认证
