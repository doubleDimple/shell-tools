#!/bin/bash

sudo apt install -y jq

set -e

echo "🚀 获取 VNIC 元数据..."
vnics=$(curl -s http://169.254.169.254/opc/v1/vnics/)
count=$(echo "$vnics" | jq length)
echo "🔍 共检测到 $count 个 VNIC（包括 eth0）"

# 策略路由表从 201 开始
table_id=201

# 从第1个附加VNIC开始（eth0是[0]，跳过）
for i in $(seq 1 $((count - 1))); do
  echo ""
  echo "⚙️ 正在处理第 $i 个附加 VNIC"

  ip=$(echo "$vnics" | jq -r ".[$i].privateIp")
  subnet=$(echo "$vnics" | jq -r ".[$i].subnetCidrBlock")
  gateway=$(echo "$vnics" | jq -r ".[$i].virtualRouterIp")
  mac=$(echo "$vnics" | jq -r ".[$i].macAddr" | tr '[:upper:]' '[:lower:]')

  # 查找接口名（更健壮）
  iface=$(ip -o link | awk -F': ' '{print $2}' | sed 's/@.*//' | while read line; do
  ip link show "$line" | grep -qi "$mac" && echo "$line" && break
  done)

  if [ -z "$iface" ]; then
    echo "❌ 未找到 MAC 为 $mac 的接口，跳过..."
    continue
  fi

  echo "  ✅ 设备名: $iface"
  echo "  🧠 IP地址: $ip"
  echo "  🌐 子网段: $subnet"
  echo "  🚪 网关:   $gateway"

  # 1. 分配 IP 地址
  sudo ip addr add "$ip/24" dev "$iface" || true

  # 2. 启动接口
  sudo ip link set "$iface" up

  # 3. 设置策略路由表
  table_name="vnic_$i"
  grep -q "$table_name" /etc/iproute2/rt_tables || echo "$table_id $table_name" | sudo tee -a /etc/iproute2/rt_tables

  # 清除已有规则（防止重复）
  sudo ip rule del from "$ip" table "$table_name" 2>/dev/null || true
  sudo ip route flush table "$table_name"

  # 添加路由规则
  sudo ip rule add from "$ip" table "$table_name"
  sudo ip route add "$subnet" dev "$iface" src "$ip" table "$table_name"
  sudo ip route add default via "$gateway" dev "$iface" table "$table_name"

  echo "✅ $iface 配置完成（路由表 $table_name）"

  # 自增路由表编号
  table_id=$((table_id + 1))
done

echo ""
echo "🎉 所有附加 VNIC 配置完成"
