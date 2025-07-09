#!/bin/bash

DOMAIN="$1"
EMAIL="$2"
SERVICE_PORT="${3:-80}"  # 默认为80
MAX_RETRY=3
RETRY=0

err_log="/tmp/apply_ssl_error.log"
> $err_log

# 输出错误并高亮
print_error() {
    echo -e "\033[31m[错误] $1\033[0m"
    [[ -f "$2" && -s "$2" ]] && { echo "详细日志："; cat "$2"; }
}

# 检查依赖，自动安装
check_dependency() {
    dep=$1
    if ! command -v $dep &>/dev/null; then
        echo "[排错] 未检测到 $dep，尝试自动安装..."
        if command -v apt &>/dev/null; then
            apt update && apt install -y $dep
        elif command -v yum &>/dev/null; then
            yum install -y $dep
        else
            print_error "未检测到支持的包管理器，无法自动安装 $dep，请手动安装！"
            exit 1
        fi
        # 再次检测
        if ! command -v $dep &>/dev/null; then
            print_error "依赖 $dep 安装失败！"
            exit 1
        fi
    fi
}

# 检查网络
check_network() {
    if ! ping -c 1 1.1.1.1 &>/dev/null; then
        print_error "网络不可用，请检查服务器网络！"
        exit 1
    fi
}

get_ipv4() { curl -s https://ipv4.icanhazip.com || curl -s https://api.ipify.org; }
get_ipv6() { curl -s https://ipv6.icanhazip.com || curl -s https://api6.ipify.org; }
resolve_ipv4() { dig +short A "$DOMAIN" | tail -n1; }
resolve_ipv6() { dig +short AAAA "$DOMAIN" | tail -n1; }

check_dns() {
    check_dependency dig
    local my_ipv4=$(get_ipv4)
    local my_ipv6=$(get_ipv6)
    local dns_ipv4=$(resolve_ipv4)
    local dns_ipv6=$(resolve_ipv6)
    echo "检测本机IPv4: $my_ipv4"
    echo "检测本机IPv6: $my_ipv6"
    echo "域名解析IPv4: $dns_ipv4"
    echo "域名解析IPv6: $dns_ipv6"
    if [[ "$my_ipv4" == "$dns_ipv4" || "$my_ipv6" == "$dns_ipv6" ]]; then
        echo "域名解析正确，继续执行"
        return 0
    else
        print_error "域名未解析到本机，暂停脚本，请检查DNS！"
        echo "[建议] 你可以尝试刷新 DNS 缓存，或等生效后重试。"
        return 1
    fi
}

check_and_open_firewall_port() {
    PORT=$1
    echo "检测端口 $PORT 的防火墙规则..."
    # 检查 firewalld
    if systemctl status firewalld >/dev/null 2>&1; then
        check_dependency firewall-cmd
        if firewall-cmd --query-port=${PORT}/tcp >/dev/null 2>&1; then
            if firewall-cmd --query-port=${PORT}/tcp | grep yes >/dev/null; then
                echo "firewalld 已经开放端口 $PORT"
                return 0
            fi
        fi
        echo "firewalld 未开放端口 $PORT"
        read -p "是否自动放行该端口？[Y/N]: " yn
        case $yn in
            [Yy]* )
                firewall-cmd --permanent --add-port=${PORT}/tcp 2>>$err_log
                firewall-cmd --reload 2>>$err_log
                if [[ $? -ne 0 ]]; then
                    print_error "firewalld 操作失败！" "$err_log"
                    exit 1
                fi
                echo "已通过 firewalld 放行端口 $PORT"
                ;;
            * )
                print_error "请手动放行端口 $PORT，脚本退出。"
                exit 1
                ;;
        esac
        return 0
    fi
    # 检查 ufw
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -w "$PORT" | grep -w "ALLOW" >/dev/null; then
            echo "ufw 已经开放端口 $PORT"
            return 0
        fi
        echo "ufw 未开放端口 $PORT"
        read -p "是否自动放行该端口？[Y/N]: " yn
        case $yn in
            [Yy]* )
                ufw allow $PORT/tcp 2>>$err_log
                if [[ $? -ne 0 ]]; then
                    print_error "ufw 操作失败！" "$err_log"
                    exit 1
                fi
                echo "已通过 ufw 放行端口 $PORT"
                ;;
            * )
                print_error "请手动放行端口 $PORT，脚本退出。"
                exit 1
                ;;
        esac
        return 0
    fi
    # 检查 iptables
    if command -v iptables >/dev/null 2>&1; then
        if iptables -L INPUT -n | grep "dpt:$PORT" | grep ACCEPT >/dev/null; then
            echo "iptables 已经开放端口 $PORT"
            return 0
        fi
        echo "iptables 未开放端口 $PORT"
        read -p "是否自动放行该端口？[Y/N]: " yn
        case $yn in
            [Yy]* )
                iptables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>>$err_log
                service iptables save 2>/dev/null || iptables-save > /etc/iptables.rules 2>/dev/null
                if [[ $? -ne 0 ]]; then
                    print_error "iptables 操作失败！" "$err_log"
                    exit 1
                fi
                echo "已通过 iptables 放行端口 $PORT"
                ;;
            * )
                print_error "请手动放行端口 $PORT，脚本退出。"
                exit 1
                ;;
        esac
        return 0
    fi
    echo "[提示] 未检测到受支持的防火墙系统（firewalld/ufw/iptables），请自行确保端口已放行！"
}

show_port_info() {
    PORT=$1
    check_dependency lsof
    check_dependency fuser
    if lsof -i :$PORT &>/dev/null; then
        echo "端口 $PORT 被以下进程占用："
        lsof -i :$PORT
        read -p "是否释放该端口？[Y/N]: " yn
        case $yn in
            [Yy]* )
                fuser -k ${PORT}/tcp 2>>$err_log
                if [[ $? -ne 0 ]]; then
                    print_error "端口释放失败！" "$err_log"
                    exit 1
                fi
                echo "已释放端口 $PORT"
                ;;
            * )
                print_error "请先手动释放端口 $PORT，脚本退出。"
                exit 1
                ;;
        esac
    fi
}

error_handler() {
    print_error "检测或执行失败，自动修复中…"
    sleep 2
    rm -rf ~/.acme.sh/"$DOMAIN" 2>>$err_log
    sleep 2
}

acme_apply() {
    check_dependency curl
    check_dependency lsof
    check_dependency fuser

    # 检查并安装acme.sh
    if ! command -v acme.sh >/dev/null 2>&1; then
        echo "[排错] 未检测到 acme.sh，尝试自动安装..."
        curl https://get.acme.sh | sh >>$err_log 2>&1
        source ~/.bashrc
        if ! command -v acme.sh >/dev/null 2>&1; then
            print_error "acme.sh 安装失败！" "$err_log"
            exit 1
        fi
    fi

    check_and_open_firewall_port $SERVICE_PORT

    show_port_info $SERVICE_PORT
    show_port_info 443

    ~/.acme.sh/acme.sh --register-account -m $EMAIL >>$err_log 2>&1
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --httpport $SERVICE_PORT --force >>$err_log 2>&1
    if [[ $? -eq 0 ]]; then
        echo -e "\033[32m✅ 证书申请成功！文件在~/.acme.sh/$DOMAIN\033[0m"
        # 检查自动续期cron
        crontab -l | grep 'acme.sh --cron' >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo "添加acme.sh自动续期任务"
            (crontab -l 2>/dev/null; echo "0 0 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null") | crontab -
        fi
    else
        print_error "acme.sh 证书签发失败！" "$err_log"
        echo "[建议] 常见原因包括：端口未放行、端口被占用、域名未正确解析到服务器。"
        return 1
    fi
}

main() {
    check_network
    check_dependency curl
    while (( RETRY < MAX_RETRY )); do
        if check_dns "$DOMAIN"; then
            acme_apply && exit 0
        else
            error_handler
        fi
        ((RETRY++))
    done
    print_error "❌ 多次重试失败，请手动检查并参考上面错误提示！" "$err_log"
    exit 1
}

main
