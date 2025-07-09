#!/bin/bash

DOMAIN="$1"
EMAIL="$2"
CF_API_TOKEN="$3"
MAX_RETRY=3
RETRY=0
err_log="/tmp/apply_ssl_cf_error.log"
stage_log="/tmp/apply_ssl_cf_stage.log"
> "$err_log"
> "$stage_log"

log_stage() {
    echo -e "\033[34m[阶段] $1\033[0m" | tee -a "$stage_log"
}

print_error() {
    echo -e "\033[31m[错误] $1\033[0m" | tee -a "$stage_log"
    [[ -f "$2" && -s "$2" ]] && { echo -e "\033[33m[详细日志]:\033[0m"; cat "$2"; }
}

check_dependency() {
    dep=$1
    package_name=${2:-$dep}
    log_stage "检查依赖：$dep"

    if ! command -v "$dep" &>/dev/null; then
        echo "[排错] 缺少 $dep，尝试安装 $package_name..." | tee -a "$stage_log"
        if command -v apt &>/dev/null; then
            apt update >>"$err_log" 2>&1 && apt install -y "$package_name" >>"$err_log" 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y "$package_name" >>"$err_log" 2>&1
        else
            print_error "不支持的系统包管理器，无法安装 $package_name" "$err_log"
            exit 1
        fi
        command -v "$dep" &>/dev/null || { print_error "$dep 安装失败" "$err_log"; exit 1; }
    else
        echo "[依赖] $dep 已存在。" | tee -a "$stage_log"
    fi
}

install_acme() {
    log_stage "安装 acme.sh"
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        echo "正在安装 acme.sh..." | tee -a "$stage_log"
        curl https://get.acme.sh | sh >>"$err_log" 2>&1
        if [[ ! -f ~/.acme.sh/acme.sh ]]; then
            print_error "acme.sh 安装失败" "$err_log"
            exit 1
        fi
    else
        echo "acme.sh 已存在。" | tee -a "$stage_log"
    fi
}

setup_cf_env() {
    log_stage "配置 Cloudflare API 环境变量"
    export CF_Token="$CF_API_TOKEN"
    export CF_Email="$EMAIL"
    echo "已配置 CF_Token 与 CF_Email。" | tee -a "$stage_log"
}

apply_cert() {
    log_stage "开始申请证书"
    ~/.acme.sh/acme.sh --register-account -m "$EMAIL" >>"$err_log" 2>&1
    CF_Token="$CF_API_TOKEN" CF_Email="$EMAIL" ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force >>"$err_log" 2>&1
    status=$?
    if [[ $status -eq 0 ]]; then
        echo -e "\033[32m[成功] 证书申请成功。\033[0m" | tee -a "$stage_log"
    else
        echo -e "\033[31m[失败] 证书申请失败。\033[0m" | tee -a "$stage_log"
    fi
    return $status
}

add_cronjob() {
    log_stage "检查自动续期任务"
    if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
        echo "添加自动续期任务..." | tee -a "$stage_log"
        (crontab -l 2>/dev/null; echo "0 2 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null 2>&1") | crontab -
    else
        echo "自动续期任务已存在。" | tee -a "$stage_log"
    fi
}

show_cert_path() {
    echo -e "\033[32m[结果] 证书申请成功！路径：~/.acme.sh/$DOMAIN/\033[0m" | tee -a "$stage_log"
    echo "证书文件：" | tee -a "$stage_log"
    echo "  - cert: ~/.acme.sh/$DOMAIN/$DOMAIN.cer" | tee -a "$stage_log"
    echo "  - key : ~/.acme.sh/$DOMAIN/$DOMAIN.key" | tee -a "$stage_log"
    echo "  - full: ~/.acme.sh/$DOMAIN/fullchain.cer" | tee -a "$stage_log"
}

main() {
    log_stage "启动脚本"
    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$CF_API_TOKEN" ]] && {
        print_error "用法: $0 <域名> <邮箱> <CF_API_TOKEN>" "$err_log"
        exit 1
    }

    check_dependency curl curl
    install_acme
    setup_cf_env

    while (( RETRY < MAX_RETRY )); do
        if apply_cert; then
            show_cert_path
            add_cronjob
            log_stage "全部步骤完成"
            exit 0
        else
            print_error "证书申请失败（第 $((RETRY+1)) 次），查看 $err_log 获取详细日志。" "$err_log"
        fi
        ((RETRY++))
        echo "等待重试中（第 $RETRY 次）..." | tee -a "$stage_log"
        sleep 5
    done

    print_error "❌ 多次尝试失败，请检查 $err_log。" "$err_log"
    exit 1
}

main
