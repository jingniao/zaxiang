#!/usr/bin/env bash
set -e

echo "====== Cloudflare 自动申请证书脚本 ======"
echo

# =========================
# 输入信息
# =========================
read -p "请输入 Cloudflare 邮箱: " CF_EMAIL
read -s -p "请输入 Cloudflare Global API Key: " CF_KEY
echo
read -p "请输入要申请证书的域名 (例如 example.com): " DOMAIN

if [[ -z "$CF_EMAIL" || -z "$CF_KEY" || -z "$DOMAIN" ]]; then
    echo "错误：输入不能为空"
    exit 1
fi

# =========================
# 当前目录
# =========================
WORKDIR=$(pwd)

# 证书保存目录
CERT_DIR="${WORKDIR}/${DOMAIN}"

mkdir -p "${CERT_DIR}"

echo
echo "证书将保存到:"
echo "${CERT_DIR}"
echo

# =========================
# 安装依赖
# =========================
echo "检查并安装依赖..."

if command -v apt >/dev/null 2>&1; then

    apt update -y
    apt install -y curl socat cron

    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true

elif command -v yum >/dev/null 2>&1; then

    yum install -y curl socat cronie

    systemctl enable crond >/dev/null 2>&1 || true
    systemctl start crond >/dev/null 2>&1 || true

else

    echo "错误：不支持当前系统的软件包管理器"
    exit 1

fi

# =========================
# 安装 acme.sh
# =========================
if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then

    echo
    echo "安装 acme.sh..."

    curl https://get.acme.sh | sh -s email="${CF_EMAIL}"

fi

ACME="${HOME}/.acme.sh/acme.sh"

if [ ! -f "$ACME" ]; then
    echo "错误：acme.sh 安装失败"
    exit 1
fi

# =========================
# 设置 Let's Encrypt
# =========================
echo
echo "设置默认 CA 为 Let's Encrypt..."

"$ACME" --set-default-ca --server letsencrypt

# =========================
# 设置 Cloudflare API
# =========================
export CF_Email="${CF_EMAIL}"
export CF_Key="${CF_KEY}"

echo
echo "开始申请证书..."
echo
echo "域名：${DOMAIN}"
echo "通配符：*.${DOMAIN}"
echo
echo "DNS TXT 写入后将等待 120 秒..."
echo

# =========================
# 申请证书
# =========================
"$ACME" --issue \
    --dns dns_cf \
    -d "${DOMAIN}" \
    -d "*.${DOMAIN}" \
    --keylength ec-256 \
    --dnssleep 120

# =========================
# 安装证书
# =========================
echo
echo "正在安装证书..."

"$ACME" --install-cert \
    -d "${DOMAIN}" \
    --ecc \
    --key-file "${CERT_DIR}/private.key" \
    --fullchain-file "${CERT_DIR}/fullchain.crt"

# =========================
# 检查文件
# =========================
if [[ ! -f "${CERT_DIR}/private.key" ]]; then
    echo "错误：没有找到私钥文件"
    exit 1
fi

if [[ ! -f "${CERT_DIR}/fullchain.crt" ]]; then
    echo "错误：没有找到证书文件"
    exit 1
fi

# =========================
# 设置权限
# =========================
chmod 600 "${CERT_DIR}/private.key"
chmod 644 "${CERT_DIR}/fullchain.crt"

# =========================
# 完成
# =========================
echo
echo "======================================"
echo "证书申请成功"
echo "======================================"
echo
echo "域名:"
echo "${DOMAIN}"
echo
echo "证书目录:"
echo "${CERT_DIR}"
echo
echo "Fullchain:"
echo "${CERT_DIR}/fullchain.crt"
echo
echo "Private Key:"
echo "${CERT_DIR}/private.key"
echo
echo "自动续期:"
echo "acme.sh 已通过 cron 自动续期"
echo
echo "======================================"
