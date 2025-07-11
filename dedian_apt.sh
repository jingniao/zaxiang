#!/bin/bash

set -e

echo "备份原有 sources.list 为 /etc/apt/sources.list.bak"
cp /etc/apt/sources.list /etc/apt/sources.list.bak

cat >/etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian/ bullseye main contrib non-free
deb-src http://archive.debian.org/debian/ bullseye main contrib non-free
deb http://archive.debian.org/debian/ bullseye-updates main contrib non-free
deb-src http://archive.debian.org/debian/ bullseye-updates main contrib non-free
deb http://archive.debian.org/debian/ bullseye-backports main contrib non-free
deb-src http://archive.debian.org/debian/ bullseye-backports main contrib non-free
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

echo "更新软件包索引"
apt update

echo "安装 unzip curl wget"
apt install -y unzip curl wget

echo "修复完成"
