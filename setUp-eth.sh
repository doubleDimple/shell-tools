#!/bin/bash

sudo apt install -y jq

set -e

# 确保 jq 安装
if ! command -v jq >/dev/null 2>&1; then
  echo "jq 未安装，正在安装..."
  sudo apt update
  sudo apt install -y jq
fi

echo "🚀 获取 VNIC 元数据..."
vnics=$(curl -s http://169.254.169.254/opc/v1/vnics/)
count=$(echo "$vnics" | jq length)
echo "🔍 共检测到 $count 个 VNIC（包括 eth0）"

# 策略路由表从 201 开始（IPv4）
table_id=201

for i in $(seq 1 $((count - 1))); do
  echo ""
  echo "⚙️ 正在处理第 $i 个附加 VNIC"

  # 提取 IPv4 相关信息
  ip4=$(echo "$vnics" | jq -r ".[$i].privateIp")
  subnet4=$(echo "$vnics" | jq -r ".[$i].subnetCidrBlock")
  gateway4=$(echo "$vnics" | jq -r ".[$i].virtualRouterIp")

  # 提取 IPv6 相关信息（数组第一个 IPv6 地址）
  ip6=$(echo "$vnics" | jq -r ".[$i].ipv6Addresses[0]")
  subnet6=$(echo "$vnics" | jq -r ".[$i].ipv6SubnetCidrBlock")
  gateway6=$(echo "$vnics" | jq -r ".[$i].ipv6VirtualRouterIp")

  mac=$(echo "$vnics" | jq -r ".[$i].macAddr" | tr '[:upper:]' '[:lower:]')

  # 查找接口名，去掉 @ 后缀
  iface=$(ip -o link | awk -F': ' '{print $2}' | sed 's/@.*//' | while read line; do
    ip link show "$line" | grep -qi "$mac" && echo "$line" && break
  done)

  if [ -z "$iface" ]; then
    echo "❌ 未找到 MAC 为 $mac 的接口，跳过..."
    continue
  fi

  echo "  ✅ 设备名: $iface"

  ### IPv4 配置 ###
  echo "  🧠 IPv4 地址: $ip4"
  echo "  🌐 IPv4 子网段: $subnet4"
  echo "  🚪 IPv4 网关:   $gateway4"

  sudo ip addr add "$ip4/24" dev "$iface" || true
  sudo ip link set "$iface" up

  table_name="vnic_$i"
  grep -q "$table_name" /etc/iproute2/rt_tables || echo "$table_id $table_name" | sudo tee -a /etc/iproute2/rt_tables

  sudo ip rule del from "$ip4" table "$table_name" 2>/dev/null || true
  sudo ip route flush table "$table_name"

  sudo ip rule add from "$ip4" table "$table_name"
  sudo ip route add "$subnet4" dev "$iface" src "$ip4" table "$table_name"
  sudo ip route add default via "$gateway4" dev "$iface" table "$table_name"

  echo "  ✅ IPv4 配置完成"

  ### IPv6 配置 ###
  if [[ "$ip6" != "null" && "$subnet6" != "null" && "$gateway6" != "null" ]]; then
    echo "  🌈 IPv6 地址: $ip6"
    echo "  🌐 IPv6 子网段: $subnet6"
    echo "  🚪 IPv6 网关:   $gateway6"

    sudo ip -6 addr add "$ip6/64" dev "$iface" || true
    # 启动接口（已启动无妨）
    sudo ip link set "$iface" up

    # 默认 IPv6 路由 metric 设置较高，防止覆盖 eth0 默认路由
    sudo ip -6 route add default via "$gateway6" dev "$iface" metric 100 || true

    echo "  ✅ IPv6 配置完成"
  else
    echo "  ⚠️ 无有效 IPv6 信息，跳过 IPv6 配置"
  fi

  # 路由表编号递增
  table_id=$((table_id + 1))
done

echo ""
echo "🎉 所有附加 VNIC IPv4 和 IPv6 配置完成"
