第一步: 再master上执行
chmod +x install-master.sh
./install-master.sh

第二步: 📌 脚本执行完会打印出：(请保存这个 join 命令，Worker 节点会用到！)
kubeadm join 192.168.0.10:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:xxxxxxxx

第三步: 在每台 Worker 节点上执行以下脚本（install-worker.sh）：
chmod +x install-worker.sh
./install-worker.sh

第四步: 然后执行 Master 节点上给出的 join 命令。

第五步: 验证集群是否成功
kubectl get nodes

你应该看到类似：
NAME               STATUS   ROLES           AGE     VERSION
master-node        Ready    control-plane   15m     v1.29.x
worker-node-1      Ready    <none>          5m      v1.29.x
worker-node-2      Ready    <none>          3m      v1.29.x

第六步: 访问 KubeSphere 面板
kubectl get svc -n kubesphere-system
找到 ks-console：
NAME          TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
ks-console    NodePort   10.96.34.5      <none>        30880:30880/TCP  10m

第七步: 浏览器访问：http://<Master 节点 IP>:30880
账号：admin
密码：P@88w0rd

第八步: 总结
| 项目     | 内容                             |
| ------ | ------------------------------ |
| 部署方式   | kubeadm + flannel + KubeSphere |
| 多节点支持  | ✅ Master + 多个 Worker           |
| 面板地址   | http\://Master\_IP:30880       |
| 默认账号密码 | admin / P\@88w0rd              |
| 权限控制   | 支持多租户、RBAC、安全认证等               |

