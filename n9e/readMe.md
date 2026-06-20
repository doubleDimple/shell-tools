# 夜莺(Nightingale)极简单机部署脚本

一个脚本搞定夜莺监控的**母鸡(中心服务端)**和**节点(被监控机器)**部署。

母鸡端纯二进制运行,**无需 Docker / MySQL / Redis**:

- `n9e`(夜莺 v8):默认使用 **SQLite + 内置 miniredis**,零外部数据库依赖
- `VictoriaMetrics`:单机版时序库,存储采集到的指标,默认只保留 **1 天**数据
- 节点端只安装一个 `Categraf` 采集器,自动接入母鸡

---

## 架构

```
        ┌─────────────────────── 母鸡 (master) ───────────────────────┐
        │  n9e (:17000)  ──写入──►  VictoriaMetrics (:8428, 存1天)     │
        │  SQLite + miniredis(内置,无需额外安装)                      │
        └──────────────────────────▲──────────────────────────────────┘
                                    │ 数据 + 心跳 (:17000)
         ┌──────────────┬──────────┴───────────┬──────────────┐
      节点1            节点2                  节点3   ...   (Categraf 采集器)
```

---

## 环境要求

- Linux,x86_64 或 arm64
- root 权限
- 已安装 `curl`、`tar`
- 母鸡需放行 **TCP 17000**(云服务器记得配安全组)

---

## 快速开始

### 1. 部署母鸡(只做一次)

```bash
curl -fsSL https://raw.githubusercontent.com/doubleDimple/shell-tools/master/n9e-deploy.sh -o n9e-deploy.sh
chmod +x n9e-deploy.sh
sudo ./n9e-deploy.sh master
```

装完后脚本会**自动打印节点接入命令(母鸡 IP 已填好)**,复制它到节点上执行即可。

部署完成后访问:`http://母鸡IP:17000`
默认账号 `root` / 默认密码 `root.2020`(**登录后请立即修改密码**)。

### 2. 部署节点(每台被监控机器执行一次)

把脚本拷到节点(scp 示例):

```bash
scp n9e-deploy.sh root@节点IP:/root/
```

然后在节点上执行(把 `母鸡IP` 换成实际地址):

```bash
sudo bash n9e-deploy.sh node 母鸡IP
```

约 10~30 秒后,到夜莺页面 **基础设施 → 机器列表** 即可看到该机器,开始采集 CPU / 内存 / 磁盘 / 网络等指标。

---

## 角色说明

脚本用同一个文件支持两种角色,三种指定方式:

| 方式 | 命令 |
| --- | --- |
| 显式母鸡 | `sudo ./n9e-deploy.sh master` |
| 显式节点 | `sudo ./n9e-deploy.sh node 母鸡IP` |
| 环境变量节点 | `N9E_SERVER=母鸡IP sudo ./n9e-deploy.sh node` |
| 自动判断 | `sudo ./n9e-deploy.sh`(已装夜莺则当母鸡重装,否则交互询问) |

---

## 一行命令安装(可选)

仓库公开后,也可以不下载直接跑:

```bash
# 母鸡
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/n9e-deploy.sh | sudo bash -s -- master

# 节点
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/n9e-deploy.sh | sudo bash -s -- node 母鸡IP
```

> 注:用一行命令装母鸡时,结尾打印的"节点命令"里脚本名会显示成 `bash`,属正常现象,按本 README 的节点命令执行即可。

---

## 常用运维命令

```bash
# 查看服务状态
systemctl status n9e victoria-metrics      # 母鸡
systemctl status categraf                  # 节点

# 重启
systemctl restart n9e
systemctl restart categraf

# 看日志
journalctl -u n9e -f
journalctl -u victoria-metrics -f
journalctl -u categraf -f
```

---

## 可配置参数(环境变量)

在命令前加环境变量即可覆盖默认值,例如:

```bash
RETENTION=7d sudo ./n9e-deploy.sh master
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `RETENTION` | `1d` | 时序数据保留期,支持 `1d` / `3d` / `7d` / `1m` 等 |
| `N9E_VERSION` | `v8.2.0` | 夜莺版本(**必须 v8+** 才默认 SQLite + miniredis) |
| `VM_VERSION` | `v1.135.0` | VictoriaMetrics 版本(见下方注意事项) |
| `N9E_PORT` | `17000` | 夜莺端口 |
| `VM_PORT` | `8428` | 时序库端口 |
| `CATEGRAF_VERSION` | 自动取最新 | 采集器版本 |
| `N9E_SERVER` | 空 | 母鸡 IP(节点模式) |

---

## 注意事项

- **VictoriaMetrics 版本别选 LTS 企业版**:`v1.136.x` / `v1.122.x` 这类 LTS 线**只发布企业版**,没有社区版单机包,会下载 404。要选**主线社区版**(文件名不带 `-enterprise`),默认的 `v1.135.0` 已验证可用。
- **内网 / 外网 IP**:母鸡自动探测的可能是内网 IP。若节点在外网,请把节点命令里的 IP 换成母鸡的**公网地址**,并放行安全组的 17000 端口。
- **母鸡自我监控**:想让母鸡自己也出现在机器列表,在母鸡上再跑一次:
  ```bash
  sudo bash n9e-deploy.sh node 127.0.0.1
  ```
- **数据保留**:真正占空间的是指标(时序)数据,由 `RETENTION` 控制;告警事件存在 SQLite 里,体积很小。
- **生产环境**:SQLite + miniredis 适合单机 / 小规模 / 自用。若要高可用或大规模,建议改用外部 MySQL + Redis,并将时序库独立部署。

---

## 卸载

```bash
# 母鸡
systemctl disable --now n9e victoria-metrics
rm -f /etc/systemd/system/n9e.service /etc/systemd/system/victoria-metrics.service
systemctl daemon-reload
rm -rf /opt/n9e /opt/victoria-metrics

# 节点
systemctl disable --now categraf
rm -f /etc/systemd/system/categraf.service
systemctl daemon-reload
rm -rf /opt/categraf
```

---

## 相关链接

- 夜莺官网文档:https://flashcat.cloud/docs/
- 夜莺 GitHub:https://github.com/ccfos/nightingale
- Categraf:https://github.com/flashcatcloud/categraf
- VictoriaMetrics:https://github.com/VictoriaMetrics/VictoriaMetrics
