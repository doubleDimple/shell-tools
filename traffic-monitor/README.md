# Traffic Monitor · 服务器流量监控

> 仓库路径：[`doubleDimple/shell-tools/traffic-monitor`](https://github.com/doubleDimple/shell-tools/tree/master/traffic-monitor)

监控网卡 **日/月流量**，阈值告警，并通过 **Telegram 内联菜单** 查看状态、改配置、启停守护。

- 纯 Bash + curl + python3，无额外运行时
- 终端菜单支持 **↑/↓ 方向键** 选择
- Telegram **消息内按钮**（非常驻底部键盘），配置可全在 TG 完成
- 支持守护进程 / crontab
- **多机 Master/Agent**：一条命令 SSH 纳管，中控查询与检查

---

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/doubleDimple/shell-tools/master/traffic-monitor/install.sh)
```
或：

```bash
curl -fsSL https://raw.githubusercontent.com/doubleDimple/shell-tools/master/traffic-monitor/install.sh | bash
```

> 通过管道安装时若无法交互，装完后执行：  
> `/opt/traffic-monitor/traffic-monitor.sh --setup`

### 常用环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `INSTALL_DIR` | `/opt/traffic-monitor` | 安装目录 |
| `RUN_SETUP` | `true` | 是否安装后进入交互配置 |
| `GITHUB_REPO` | `doubleDimple/shell-tools` | 仓库 |
| `GITHUB_BRANCH` | `master` | 分支 |
| `GITHUB_SUBDIR` | `traffic-monitor` | 子目录 |

示例：装到自定义目录且暂不配置：

```bash
INSTALL_DIR=/root/tm RUN_SETUP=false \
  bash <(curl -fsSL https://raw.githubusercontent.com/doubleDimple/shell-tools/master/traffic-monitor/install.sh)
```

---

## 角色说明

| ROLE | 含义 |
|------|------|
| `standalone` | 单机（默认），本机采集 + 可选 TG 菜单轮询 |
| `master` | 中控：纳管多台 Agent，**唯一**建议开启 TG 菜单轮询 |
| `agent` | 被纳管节点：本机采集 + 本地告警；**不**轮询 TG（`TG_POLL_ENABLED=false`） |

首次 `master enroll` 会自动把本机 `ROLE` 设为 `master`。

---

## 多机部署（方案 B · SSH 纳管）

前提：

1. Master 与各 Agent 均为 **root**，且有 **公网 IP**（或 Master 能 SSH 到 Agent）
2. Master 已配置到 Agent 的 **SSH 密钥免密**（`BatchMode`）

```bash
# 在 Master 上
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519   # 若还没有密钥
ssh-copy-id root@1.2.3.4
ssh root@1.2.3.4 true                              # 确认免密
```

### 一条命令纳管

```bash
# Master 先装好并配置好 Telegram（可选，会复制到 Agent 做本地告警）
traffic-monitor --setup
# 或菜单里「设为本机 Master 角色」

# 纳管一台 Agent
traffic-monitor master enroll root@1.2.3.4 \
  --tag sg-1 \
  --iface eth0 \
  --daily 100

# 再纳管
traffic-monitor master enroll root@5.6.7.8 --tag jp-1 --daily 50
```

`enroll` 会：

1. SSH 检测连通
2. 远程安装依赖（curl/python3）
3. 同步 `traffic-monitor.sh` 到 `/opt/traffic-monitor`
4. 写入 Agent 配置（`ROLE=agent`，`TG_POLL_ENABLED=false`）
5. 安装远程 crontab 定时 `--check`（默认每 5 分钟）
6. 写入 Master 清单 `machines.conf`

### Master 日常命令

```bash
traffic-monitor master list              # 已纳管列表
traffic-monitor master status            # 全部总览
traffic-monitor master status sg-1       # 单机详情
traffic-monitor master check             # 全部触发检查/告警
traffic-monitor master check sg-1
traffic-monitor master report            # 汇总推到 Master 的 TG
traffic-monitor master exec sg-1 --status
traffic-monitor master remove sg-1       # 仅移出清单
traffic-monitor master remove sg-1 --uninstall  # 移出并删远程目录
```

### 告警与 TG 菜单

| 能力 | 行为 |
|------|------|
| 阈值告警 | **各 Agent 本地** cron/`--check` 推送（消息带 `HOSTNAME_TAG`） |
| 汇总报告 | Master `master report` 或 TG「汇总报告」 |
| TG 内联菜单 | **仅 Master** 守护进程轮询；点「🖥 多机」或发 `/hosts` |

Master 启动守护：

```bash
traffic-monitor --start
# Telegram 发 /menu → 🖥 多机
```

### Telegram 直接操作多机

| 操作 | 方式 |
|------|------|
| 打开多机面板 | `/menu` → 🖥 多机，或 `/hosts` |
| 纳管 | 按钮「➕ 纳管」或 `/enroll`，发送 `1.2.3.4 sg-1` |
| 单机面板 | 点机器名，或 `/host sg-1` |
| 状态 / 检查 / 报告 | 单机面板按钮 |
| 清零今日 | 单机 → 清零（需确认） |
| 改日/月限额、网卡、阈值、标识 | 单机 → 远程配置 |
| Cron 1/5/15 分、移除 | 单机 → Cron |
| 启停远程守护 | 单机按钮 |
| 移出清单 / 卸载 | 单机 → 移出（需确认） |
| 全部检查 | 多机面板或 `/checkall` |
| 汇总推送 | 多机面板「汇总报告」 |

---

## 交互配置向导

```bash
traffic-monitor --setup
# 或
/opt/traffic-monitor/traffic-monitor.sh --setup
```

向导会依次引导：

1. 监控网卡 / 日限额 / 月限额 / 统计模式  
2. 告警阈值与冷却  
3. Telegram Bot Token、Chat ID  
4. 发送测试消息  
5. 是否启动后台守护（含 TG 菜单监听）

无参数进入完整菜单：

```bash
traffic-monitor
```

---

## Telegram

1. 找 [@BotFather](https://t.me/BotFather) 创建 Bot，拿到 **Token**  
2. 私聊 Bot 或拉进群，用 [@userinfobot](https://t.me/userinfobot) 等获取 **Chat ID**  
3. 在向导里填入，或服务器菜单 → Telegram 配置  
4. **启动守护进程** 后，在 TG 发送 `/menu` 或 `/start`

### 内联菜单能力

| 功能 | 说明 |
|------|------|
| 状态 / 报告 / 检查 | 查看与告警 |
| 配置中心 | 网卡、限额、阈值、标识等 |
| 调度 | 启停守护、Cron、日报 |
| 日志 / 清零 | 最近日志、清零今日累计 |
| 多机（Master） | 总览、纳管、按机器：状态/检查/报告/清零/改配置/Cron/启停守护/移出 |

配置项点选后按提示 **发送文本** 即可保存，`/cancel` 取消输入。

---

## 命令一览

```bash
traffic-monitor              # 交互菜单（方向键）
traffic-monitor --setup      # 首次/重新配置向导
traffic-monitor --status     # 查看状态
traffic-monitor --check      # 更新用量并检查告警
traffic-monitor --report     # 推送 TG 报告
traffic-monitor --start      # 后台守护（按 TG_POLL 决定是否监听菜单）
traffic-monitor --stop       # 停止守护
traffic-monitor --test-tg    # 测试 Telegram
traffic-monitor --push-menu  # 推送内联主菜单
traffic-monitor --install-cron 5   # 每 5 分钟 cron 检查
traffic-monitor --install-report   # 每日 09:00/21:00 报告
traffic-monitor master help
traffic-monitor --help
```

---

## 手动安装

```bash
git clone https://github.com/doubleDimple/shell-tools.git
cd shell-tools/traffic-monitor
chmod +x traffic-monitor.sh install.sh
./traffic-monitor.sh --setup
./traffic-monitor.sh --start
```

依赖：`bash` `curl` `python3`（解析 TG 更新）；Master 另需 `ssh` / `scp`。

---

## 配置与数据

| 路径 | 说明 |
|------|------|
| `config.conf` | 配置（**含 Token，勿提交 Git**） |
| `machines.conf` | Master 纳管清单（**含主机信息，勿提交**） |
| `state/` | 流量累计、PID、TG 会话 |
| `traffic-monitor.log` | 日志 |

仓库内仅提供 `config.conf.example`。`.gitignore` 已忽略真实配置与状态。

---

## 安全说明

- `config.conf` / `machines.conf` 权限建议 `600`  
- 仅响应配置中的 `TG_CHAT_ID`，其它会话忽略  
- **不要**把含真实 Token 的配置推到公开仓库  
- 若 Token 曾泄露，请在 BotFather 里 **Revoke** 并换新  
- Master 持有到各机的 root SSH，请保护好 Master 主机与私钥  
- Agent 默认 **不** 轮询 TG，避免多机抢 `getUpdates`

---

## License

MIT（可按需自行修改）
