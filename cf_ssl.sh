#!/bin/bash

DOMAIN="$1"
EMAIL="$2"
CF_API_TOKEN="$3"
MAX_RETRY=3
RETRY=0
err_log="/tmp/apply_ssl_cf_error.log"
> "$err_log"

# 输出错误
print_error() {
    echo -e "\033[31m[错误] $1\033[0m"
    [[ -f "$2" && -s "$2" ]] && { echo "详细日志："; cat "$2"; }
}

# 检查依赖
check_dependency() {
    dep=$1
    package_name=${2:-$dep}

    if ! command -v "$dep" &>/dev/null; then
        echo "[排错] 缺少 $dep，安装 $package_name..." | tee -a "$err_log"
        if command -v apt &>/dev/null; then
            apt update >>"$err_log" 2>&1 && apt install -y "$package_name" >>"$err_log" 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y "$package_name" >>"$err_log" 2>&1
        else
            print_error "不支持的系统包管理器，无法安装 $package_name" "$err_log"
            exit 1
        fi
        command -v "$dep" &>/dev/null || { print_error "$dep 安装失败" "$err_log"; exit 1; }
    fi
}

# 安装 acme.sh
install_acme() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        echo "正在安装 acme.sh..." | tee -a "$err_log"
        curl https://get.acme.sh | sh >>"$err_log" 2>&1
        if [[ ! -f ~/.acme.sh/acme.sh ]]; then
            print_error "acme.sh 安装失败" "$err_log"
            exit 1
        fi
    fi
}

# 设置 Cloudflare API Token (仅影响acme.sh命令，不污染全局)
setup_cf_env() {
    export CF_Token="$CF_API_TOKEN"
    export CF_Email="$EMAIL"
}

# 申请证书，输出详细日志
apply_cert() {
    ~/.acme.sh/acme.sh --register-account -m "$EMAIL" >>"$err_log" 2>&1
    # 通过env传递变量，不污染全局
    CF_Token="$CF_API_TOKEN" CF_Email="$EMAIL" ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force >>"$err_log" 2>&1
    return $?
}

# 主逻辑
main() {
    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$CF_API_TOKEN" ]] && {
        echo "用法: $0 <域名> <邮箱> <CF_API_TOKEN>"
        exit 1
    }

    check_dependency curl curl

    install_acme
    setup_cf_env

    while (( RETRY < MAX_RETRY )); do
        if apply_cert; then
            echo -e "\033[32m✅ 证书申请成功！路径：~/.acme.sh/$DOMAIN/\033[0m"
            echo "证书文件："
            echo "  - cert: ~/.acme.sh/$DOMAIN/$DOMAIN.cer"
            echo "  - key : ~/.acme.sh/$DOMAIN/$DOMAIN.key"
            echo "  - full: ~/.acme.sh/$DOMAIN/fullchain.cer"
            # 自动续期
            if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
                echo "添加自动续期任务..."
                (crontab -l 2>/dev/null; echo "0 2 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null 2>&1") | crontab -
            fi
            return 0
        else
            print_error "证书申请失败（第 $((RETRY+1)) 次）。" "$err_log"
        fi
        ((RETRY++))
        echo "等待重试中（第 $RETRY 次）..."
        sleep 5
    done

    print_error "❌ 多次尝试失败，请检查错误日志。" "$err_log"
    return 1
}

main
