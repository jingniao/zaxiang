#!/usr/bin/env bash
set -e

echo "====== Cloudflare 自动申请证书脚本 ======"
echo

# 输入信息
read -p "请输入 Cloudflare 邮箱: " CF_EMAIL
read -s -p "请输入 Cloudflare Global API Key: " CF_KEY
echo
read -p "请输入要申请证书的域名 (例如 example.com): " DOMAIN

if [[ -z "$CF_EMAIL" || -z "$CF_KEY" || -z "$DOMAIN" ]]; then
    echo "输入不能为空"
    exit 1
fi

# 当前目录
WORKDIR=$(pwd)

# 证书目录
CERT_DIR="${WORKDIR}/${DOMAIN}"

mkdir -p "${CERT_DIR}"

echo
echo "证书将保存到:"
echo "$CERT_DIR"
echo

# 安装依赖
if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl socat cron
    systemctl enable cron >/dev/null 2>&1
    systemctl start cron >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl socat cronie
    systemctl enable crond >/dev/null 2>&1
    systemctl start crond >/dev/null 2>&1
fi

# 安装 acme.sh
if [ ! -f ~/.acme.sh/acme.sh ]; then
    echo "安装 acme.sh..."
    curl https://get.acme.sh | sh -s email=$CF_EMAIL
fi

ACME=~/.acme.sh/acme.sh

# 设置 CA
$ACME --set-default-ca --server letsencrypt

# 设置 CF API
export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

echo
echo "开始申请证书..."
echo

# 申请证书
$ACME --issue --dns dns_cf -d "$DOMAIN" -d "*.$DOMAIN" --keylength ec-256

# 安装证书
$ACME --install-cert -d "$DOMAIN" --ecc \
--key-file       "$CERT_DIR/private.key" \
--fullchain-file "$CERT_DIR/fullchain.crt"

echo
echo "======================================"
echo "证书申请成功"
echo
echo "域名: $DOMAIN"
echo
echo "证书路径:"
echo "公钥 (Fullchain):"
echo "$CERT_DIR/fullchain.crt"
echo
echo "私钥 (Private Key):"
echo "$CERT_DIR/private.key"
echo
echo "自动续期已启用 (acme.sh cron)"
echo "======================================"
