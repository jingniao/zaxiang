#!/bin/bash

# 用法: ./set-dns.sh               # 设置为默认 1.1.1.1 8.8.8.8
# 用法: ./set-dns.sh 1.1.1.1 9.9.9.9  # 设置为自定义 DNS

set -e

# 默认 DNS
DNS1=${1:-1.1.1.1}
DNS2=${2:-8.8.8.8}

echo "设置 DNS 为: $DNS1 和 $DNS2"

# 备份旧配置
cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak 2>/dev/null || true

# 修改 /etc/systemd/resolved.conf
sed -i '/^DNS=/d' /etc/systemd/resolved.conf
sed -i '/^FallbackDNS=/d' /etc/systemd/resolved.conf
echo "DNS=$DNS1 $DNS2" >> /etc/systemd/resolved.conf
echo "FallbackDNS=1.0.0.1 8.8.4.4" >> /etc/systemd/resolved.conf

# 确保 /etc/resolv.conf 链接正确
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# 重启服务以生效
systemctl restart systemd-resolved

echo "DNS 修改完成，当前设置如下："
resolvectl status | grep "DNS Servers"
