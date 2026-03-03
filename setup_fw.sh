#!/usr/bin/env bash
set -euo pipefail

# Debian: UFW + Fail2ban
# - Install firewall (ufw)
# - Allow SSH 22
# - Protect SSH from brute force (ufw limit + fail2ban)
# - Allow port range 35000-40000 (TCP)
#
# Usage:
#   sudo bash setup_fw.sh
#
# Optional env:
#   SSH_PORT=22
#   RANGE_FROM=35000
#   RANGE_TO=40000

SSH_PORT="${SSH_PORT:-22}"
RANGE_FROM="${RANGE_FROM:-35000}"
RANGE_TO="${RANGE_TO:-40000}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 执行：sudo bash $0"
  exit 1
fi

echo "==> 更新软件源并安装 ufw / fail2ban ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ufw fail2ban

echo "==> 配置 UFW 默认策略（拒绝入站，允许出站）..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

echo "==> 放行 SSH 端口 ${SSH_PORT}/tcp ..."
ufw allow "${SSH_PORT}/tcp" comment "SSH"

echo "==> 启用 SSH 端口限速（防暴力尝试）..."
# UFW 自带限速：同一IP短时间多次连接会被临时封禁
ufw limit "${SSH_PORT}/tcp" comment "SSH brute-force rate limit"

echo "==> 放行端口范围 ${RANGE_FROM}-${RANGE_TO}/tcp ..."
ufw allow "${RANGE_FROM}:${RANGE_TO}/tcp" comment "Custom range TCP"

# 如果你也需要 UDP（例如某些游戏/语音/传输服务），取消下一行注释：
# ufw allow "${RANGE_FROM}:${RANGE_TO}/udp" comment "Custom range UDP"

echo "==> 启用 UFW 防火墙 ..."
ufw --force enable

echo "==> 配置 Fail2ban（更强的 SSH 防爆破）..."
JAIL_LOCAL="/etc/fail2ban/jail.local"

# 备份已有配置
if [[ -f "${JAIL_LOCAL}" ]]; then
  cp -a "${JAIL_LOCAL}" "${JAIL_LOCAL}.bak.$(date +%F_%H%M%S)"
fi

cat > "${JAIL_LOCAL}" <<EOF
[DEFAULT]
# 封禁时间（秒）：1小时
bantime  = 3600
# 观察窗口（秒）：10分钟
findtime = 600
# 触发封禁的最大失败次数
maxretry = 5
# 使用 ufw 执行封禁
banaction = ufw

[sshd]
enabled = true
port    = ${SSH_PORT}
logpath = %(sshd_log)s
backend = systemd
EOF

echo "==> 启动并设置 fail2ban 开机自启 ..."
systemctl enable --now fail2ban

echo
echo "================= 完成 ================="
echo "UFW 状态："
ufw status verbose || true
echo
echo "Fail2ban 状态："
fail2ban-client status sshd || true
echo "======================================="
