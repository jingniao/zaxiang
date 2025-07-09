#!/bin/bash

DOMAIN="$1"
EMAIL="$2"
SERVICE_PORT="${3:-80}"
MAX_RETRY=3
RETRY=0
err_log="/tmp/apply_ssl_error.log"
> "$err_log"

# 错误输出
print_error() {
    echo -e "\033[31m[错误] $1\033[0m"
    [[ -f "$2" && -s "$2" ]] && { echo "详细日志："; cat "$2"; }
}

# 自动安装依赖
check_dependency() {
    dep=$1
    package_name=${2:-$dep}

    if ! command -v "$dep" &>/dev/null; then
        echo "[排错] 缺少 $dep，安装 $package_name..."
        if command -v apt &>/dev/null; then
            apt update && apt install -y "$package_name"
        elif command -v yum &>/dev/null; then
            yum install -y "$package_name"
        else
            print_error "不支持的系统包管理器，无法安装 $package_name"
            exit 1
        fi
        command -v "$dep" &>/dev/null || { print_error "$dep 安装失败" "$err_log"; exit 1; }
    fi
}

# 获取公网 IP
get_ipv4() { curl -s https://ipv4.icanhazip.com; }
get_ipv6() { curl -s https://ipv6.icanhazip.com; }

# 获取域名解析 IP
resolve_ipv4() {
    dig +short A "$DOMAIN" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}
resolve_ipv6() {
    dig +short AAAA "$DOMAIN" | grep -E '^[0-9a-fA-F:]+$'
}

# 检查域名是否解析到本机
check_dns() {
    check_dependency dig dnsutils
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)
    dns4=$(resolve_ipv4)
    dns6=$(resolve_ipv6)

    echo "本机 IPv4: $ipv4"
    echo "本机 IPv6: $ipv6"
    echo "域名 IPv4: $dns4"
    echo "域名 IPv6: $dns6"

    if [[ "$ipv4" == "$dns4" || "$ipv6" == "$dns6" ]]; then
        echo "✅ 域名解析正确"
        return 0
    else
        print_error "❌ 域名未解析到本机" "$err_log"
        return 1
    fi
}

# 检查并放行防火墙端口
check_firewall() {
    PORT=$1
    if systemctl is-active firewalld &>/dev/null && command -v firewall-cmd &>/dev/null; then
        firewall-cmd --query-port="${PORT}/tcp" | grep -q yes || {
            read -p "未放行端口 $PORT，是否自动放行？[Y/N] " yn
            [[ "$yn" =~ ^[Yy]$ ]] && {
                firewall-cmd --permanent --add-port="${PORT}/tcp"
                firewall-cmd --reload
            }
        }
    fi
}

# 检查端口是否占用
check_port_usage() {
    PORT=$1
    check_dependency lsof lsof
    check_dependency fuser psmisc

    if lsof -i ":$PORT" &>/dev/null; then
        echo "⚠️ 端口 $PORT 被占用："
        lsof -i ":$PORT"
        read -p "是否释放端口？[Y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && fuser -k "${PORT}/tcp"
    else
        echo "✅ 端口 $PORT 未被占用"
    fi
}

# 安装 acme.sh
install_acme() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        echo "正在安装 acme.sh..."
        curl https://get.acme.sh | sh
        source ~/.bashrc
    fi
}

# 申请证书
apply_cert() {
    ~/.acme.sh/acme.sh --register-account -m "$EMAIL"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --httpport "$SERVICE_PORT" --force
}

# 主程序
main() {
    [[ -z "$DOMAIN" || -z "$EMAIL" ]] && {
        echo "用法: $0 <域名> <邮箱> [端口]"
        exit 1
    }

    check_dependency curl curl
    check_dependency dig dnsutils

    while (( RETRY < MAX_RETRY )); do
        if check_dns; then
            check_firewall "$SERVICE_PORT"
            check_port_usage "$SERVICE_PORT"
            check_port_usage 443
            install_acme

            if apply_cert; then
                echo -e "\033[32m✅ 证书申请成功！路径：~/.acme.sh/$DOMAIN/\033[0m"
                echo "证书文件："
                echo "  - cert: ~/.acme.sh/$DOMAIN/$DOMAIN.cer"
                echo "  - key : ~/.acme.sh/$DOMAIN/$DOMAIN.key"
                echo "  - full: ~/.acme.sh/$DOMAIN/fullchain.cer"

                if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
                    echo "添加自动续期任务..."
                    (crontab -l 2>/dev/null; echo "0 2 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null 2>&1") | crontab -
                fi
                return 0
            fi
        fi
        ((RETRY++))
        echo "等待重试中（第 $RETRY 次）..."
        sleep 5
    done

    print_error "❌ 多次尝试失败，请检查错误日志。" "$err_log"
    return 1
}

main
