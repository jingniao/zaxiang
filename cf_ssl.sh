#!/usr/bin/env bash
set -Eeuo pipefail

ACME_HOME="/root/.acme.sh"
DEFAULT_CERT_DIR="/etc/ssl/mycert"

log() {
  echo "[INFO] $*"
}

err() {
  echo "[ERR] $*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行此脚本"
    exit 1
  fi
}

install_deps() {
  log "检查并安装依赖..."
  if command -v apt >/dev/null 2>&1; then
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y curl socat cron
    systemctl enable --now cron || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl socat cronie
    systemctl enable --now crond || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl socat cronie
    systemctl enable --now crond || true
  else
    err "不支持的系统，请手动安装 curl、socat、cron/crond"
    exit 1
  fi
}

install_acme() {
  if [[ -x "${ACME_HOME}/acme.sh" ]]; then
    log "检测到 acme.sh 已安装"
    return
  fi

  log "开始安装 acme.sh ..."
  curl https://get.acme.sh | sh -s email="${ACME_ACCOUNT_EMAIL}"

  if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
    err "acme.sh 安装失败：${ACME_HOME}/acme.sh 不存在"
    exit 1
  fi
}

upgrade_acme() {
  log "升级 acme.sh ..."
  "${ACME_HOME}/acme.sh" --upgrade --auto-upgrade
}

set_default_ca() {
  log "设置默认证书颁发机构为 Let's Encrypt ..."
  "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt
}

collect_input() {
  echo
  read -r -p "请输入 Cloudflare 邮箱: " CF_EMAIL
  read -r -s -p "请输入 Cloudflare Global API Key: " CF_KEY
  echo
  read -r -p "请输入 ACME 注册邮箱(回车默认使用 Cloudflare 邮箱): " ACME_ACCOUNT_EMAIL
  ACME_ACCOUNT_EMAIL="${ACME_ACCOUNT_EMAIL:-$CF_EMAIL}"

  read -r -p "请输入主域名(例如 example.com): " PRIMARY_DOMAIN
  read -r -p "请输入附加域名，多个用空格分隔，可留空(例如 *.example.com www.example.com): " ALT_DOMAINS
  read -r -p "请输入证书保存目录(默认 ${DEFAULT_CERT_DIR}): " CERT_DIR
  CERT_DIR="${CERT_DIR:-$DEFAULT_CERT_DIR}"
  read -r -p "请输入续期后重载命令，可留空(例如 systemctl reload nginx): " RELOAD_CMD

  if [[ -z "${CF_EMAIL}" || -z "${CF_KEY}" || -z "${PRIMARY_DOMAIN}" ]]; then
    err "Cloudflare 邮箱、API Key、主域名不能为空"
    exit 1
  fi
}

prepare_env() {
  export CF_Email="${CF_EMAIL}"
  export CF_Key="${CF_KEY}"
}

build_domain_args() {
  DOMAIN_ARGS=(-d "${PRIMARY_DOMAIN}")
  if [[ -n "${ALT_DOMAINS}" ]]; then
    for d in ${ALT_DOMAINS}; do
      DOMAIN_ARGS+=(-d "${d}")
    done
  fi
}

issue_cert() {
  log "开始申请证书 ..."
  "${ACME_HOME}/acme.sh" \
    --issue \
    --dns dns_cf \
    "${DOMAIN_ARGS[@]}" \
    --keylength ec-256
}

install_cert() {
  log "安装证书到 ${CERT_DIR} ..."
  mkdir -p "${CERT_DIR}"

  if [[ -n "${RELOAD_CMD}" ]]; then
    "${ACME_HOME}/acme.sh" \
      --install-cert \
      -d "${PRIMARY_DOMAIN}" \
      --ecc \
      --key-file "${CERT_DIR}/privkey.pem" \
      --fullchain-file "${CERT_DIR}/fullchain.pem" \
      --cert-file "${CERT_DIR}/cert.pem" \
      --ca-file "${CERT_DIR}/ca.pem" \
      --reloadcmd "${RELOAD_CMD}"
  else
    "${ACME_HOME}/acme.sh" \
      --install-cert \
      -d "${PRIMARY_DOMAIN}" \
      --ecc \
      --key-file "${CERT_DIR}/privkey.pem" \
      --fullchain-file "${CERT_DIR}/fullchain.pem" \
      --cert-file "${CERT_DIR}/cert.pem" \
      --ca-file "${CERT_DIR}/ca.pem"
  fi
}

show_result() {
  echo
  echo "========================================"
  echo "证书申请完成"
  echo "主域名: ${PRIMARY_DOMAIN}"
  echo "证书目录: ${CERT_DIR}"
  echo "私钥: ${CERT_DIR}/privkey.pem"
  echo "完整链: ${CERT_DIR}/fullchain.pem"
  echo "证书: ${CERT_DIR}/cert.pem"
  echo "CA: ${CERT_DIR}/ca.pem"
  echo
  echo "查看已签发证书:"
  echo "  ${ACME_HOME}/acme.sh --list"
  echo
  echo "手动测试续期:"
  echo "  ${ACME_HOME}/acme.sh --renew -d ${PRIMARY_DOMAIN} --ecc --force"
  echo
  echo "查看证书时间:"
  echo "  openssl x509 -in ${CERT_DIR}/fullchain.pem -noout -dates -subject"
  echo "========================================"
}

main() {
  require_root
  collect_input
  install_deps
  install_acme
  upgrade_acme
  set_default_ca
  prepare_env
  build_domain_args
  issue_cert
  install_cert
  show_result
}

main "$@"
