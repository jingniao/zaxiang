#!/bin/bash
set -e

# =========================
# VPS 初始化脚本
# Debian / Ubuntu
# =========================

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户运行"
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    echo "当前系统不是 Debian / Ubuntu，脚本退出"
    exit 1
fi

echo "================================="
echo "        VPS 初始化脚本"
echo "================================="
echo

read -rp "请输入 SSH 端口 [默认 22222]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22222}

read -rp "请输入时区 [默认 Asia/Shanghai]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Asia/Shanghai}

read -rp "请输入额外开放端口，空格分隔 [默认 80 443]: " FIREWALL_PORTS
FIREWALL_PORTS=${FIREWALL_PORTS:-"80 443"}

read -rp "请输入队列算法 fq / fq_pie / cake [默认 fq]: " QDISC
QDISC=${QDISC:-fq}

case "$QDISC" in
    fq|fq_pie|cake)
        ;;
    *)
        echo "队列算法只能是 fq / fq_pie / cake"
        exit 1
        ;;
esac

echo
echo "即将执行以下配置："
echo "SSH 端口: $SSH_PORT"
echo "时区: $TIMEZONE"
echo "开放端口: $SSH_PORT $FIREWALL_PORTS"
echo "队列算法: $QDISC"
echo

read -rp "确认执行？输入 y 继续: " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "已取消"
    exit 0
fi

echo
echo "1. 更新系统..."
apt update && apt upgrade -y

echo
echo "2. 安装基础工具、UFW、fail2ban..."
apt install -y \
curl wget vim nano git htop iotop iftop screen tmux unzip zip sudo cron \
dnsutils net-tools ca-certificates ufw fail2ban

echo
echo "3. 设置时区..."
timedatectl set-timezone "$TIMEZONE"

echo
echo "4. 配置 SSH..."

SSH_CONFIG="/etc/ssh/sshd_config"

if [ ! -f "$SSH_CONFIG" ]; then
    echo "未找到 SSH 配置文件: $SSH_CONFIG"
    exit 1
fi

cp "$SSH_CONFIG" "$SSH_CONFIG.bak.$(date +%F-%H%M%S)"

set_sshd_option() {
    local key="$1"
    local value="$2"

    if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$SSH_CONFIG"; then
        sed -i "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$SSH_CONFIG"
    else
        echo "${key} ${value}" >> "$SSH_CONFIG"
    fi
}

set_sshd_option "Port" "$SSH_PORT"
set_sshd_option "PermitRootLogin" "yes"
set_sshd_option "PasswordAuthentication" "yes"

echo
echo "5. 配置 UFW 防火墙..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

echo "开放 SSH 端口: $SSH_PORT/tcp"
ufw allow "$SSH_PORT/tcp"

echo "开放自定义端口..."

for PORT in $FIREWALL_PORTS; do
    # 支持用户直接输入 端口/tcp 或 端口/udp
    if [[ "$PORT" =~ /tcp$ || "$PORT" =~ /udp$ ]]; then
        ufw allow "$PORT"
    else
        # 默认 TCP + UDP 都开放
        ufw allow "$PORT/tcp"
        ufw allow "$PORT/udp"
    fi
done

ufw --force enable

echo
echo "6. 开启 BBR + $QDISC..."

if [ "$QDISC" = "cake" ]; then
    modprobe sch_cake 2>/dev/null || echo "提示：当前内核可能不支持 cake"
fi

if [ "$QDISC" = "fq_pie" ]; then
    modprobe sch_fq_pie 2>/dev/null || echo "提示：当前内核可能不支持 fq_pie"
fi

cat >/etc/sysctl.d/99-bbr-qdisc.conf <<EOF
net.core.default_qdisc=${QDISC}
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl --system

echo
echo "7. 配置 fail2ban..."

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = %(sshd_log)s
maxretry = 5
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo
echo "8. 检查 SSH 配置..."

if command -v sshd >/dev/null 2>&1; then
    sshd -t
fi

echo
echo "9. 重启 SSH 服务..."

if systemctl list-unit-files | grep -q "^ssh.service"; then
    systemctl restart ssh
elif systemctl list-unit-files | grep -q "^sshd.service"; then
    systemctl restart sshd
else
    echo "未找到 ssh / sshd 服务，请手动重启 SSH"
fi

echo
echo "================================="
echo "          初始化完成"
echo "================================="
echo
echo "SSH 端口: $SSH_PORT"
echo "时区: $TIMEZONE"
echo "开放端口: $SSH_PORT $FIREWALL_PORTS"
echo "队列算法: $QDISC"
echo
echo "重新连接命令："
echo "ssh -p $SSH_PORT root@你的IP"
echo
echo "常用验证命令："
echo "ufw status"
echo "fail2ban-client status sshd"
echo "sysctl net.ipv4.tcp_congestion_control"
echo "sysctl net.core.default_qdisc"
