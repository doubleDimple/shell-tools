# Traffic Monitor · 服务器流量监控

> 仓库路径：[`doubleDimple/shell-tools/traffic-monitor`](https://github.com/doubleDimple/shell-tools/tree/master/traffic-monitor)

监控网卡 **日/月流量**，阈值告警，并通过 **Telegram 内联菜单** 查看状态、改配置、启停守护。

- 纯 Bash + curl + python3，无额外运行时
- 终端菜单支持 **↑/↓ 方向键** 选择
- Telegram **消息内按钮**（非常驻底部键盘），配置可全在 TG 完成
- 支持守护进程 / crontab

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

配置项点选后按提示 **发送文本** 即可保存，`/cancel` 取消输入。

---

## 命令一览

```bash
traffic-monitor              # 交互菜单（方向键）
traffic-monitor --setup      # 首次/重新配置向导
traffic-monitor --status     # 查看状态
traffic-monitor --check      # 更新用量并检查告警
traffic-monitor --report     # 推送 TG 报告
traffic-monitor --start      # 后台守护（含 TG 监听）
traffic-monitor --stop       # 停止守护
traffic-monitor --test-tg    # 测试 Telegram
traffic-monitor --push-menu  # 推送内联主菜单
traffic-monitor --install-cron 5   # 每 5 分钟 cron 检查
traffic-monitor --install-report   # 每日 09:00/21:00 报告
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

依赖：`bash` `curl` `python3`（解析 TG 更新）

---

## 配置与数据

| 路径 | 说明 |
|------|------|
| `config.conf` | 配置（**含 Token，勿提交 Git**） |
| `state/` | 流量累计、PID、TG 会话 |
| `traffic-monitor.log` | 日志 |

仓库内仅提供 `config.conf.example`。`.gitignore` 已忽略真实配置与状态。

---

## 安全说明

- `config.conf` 权限建议 `600`  
- 仅响应配置中的 `TG_CHAT_ID`，其它会话忽略  
- **不要**把含真实 Token 的 `config.conf` 推到公开仓库  
- 若 Token 曾泄露，请在 BotFather 里 **Revoke** 并换新

---

## License

MIT（可按需自行修改）
