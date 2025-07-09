#!/bin/bash

DOMAIN="$1"
EMAIL="$2"
SERVICE_PORT="${3:-80}"
MAX_RETRY=3
RETRY=0

err_log="/tmp/apply_ssl_error.log"
> "$err_log"

# 输出错误并高亮
print_error() {
    echo -e "\033[31m[错误] $1\033[0m"
    [[ -f "$2" && -s "$2" ]] && { echo "详细日志："; cat "$2"; }
}

# 检查依赖，自动安装
check_dependency() {
    dep=$1
    package_name=${2:-$dep}
    
    if ! command -v "$dep" &>/dev/null; then
        echo "[排错] 未检测到 $dep，尝试自动安装..."
        
        if command -v apt &>/dev/null; then
            apt update >/dev/null 2>&1 && apt install -y "$package_name" 2>>"$err_log"
        elif command -v yum &>/dev/null; then
            yum install -y "$package_name" 2>>"$err_log"
        elif command -v dnf &>/dev/null; then
            dnf install -y "$package_name" 2>>"$err_log"
        else
            print_error "未检测到支持的包管理器，无法自动安装 $dep，请手动安装！"
            exit 1
        fi
        
        if ! command -v "$dep" &>/dev/null; then
            print_error "依赖 $dep 安装失败！可能需要手动安装包：$package_name" "$err_log"
            exit 1
        fi
        echo "✅ $dep 安装成功"
    fi
}

# 检查参数
check_params() {
    if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
        echo "用法: $0 <域名> <邮箱> [端口]"
        echo "示例: $0 example.com your@email.com 80"
        exit 1
    fi
    
    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "邮箱格式不正确: $EMAIL"
        exit 1
    fi
    
    if [[ ! "$SERVICE_PORT" =~ ^[0-9]+$ ]] || [[ "$SERVICE_PORT" -lt 1 || "$SERVICE_PORT" -gt 65535 ]]; then
        print_error "端口必须是1-65535之间的数字: $SERVICE_PORT"
        exit 1
    fi
}

# 检查网络
check_network() {
    if ! ping -c 1 1.1.1.1 &>/dev/null; then
        print_error "网络不可用，请检查服务器网络！"
        exit 1
    fi
}

get_public_ipv4() { 
    curl -s --connect-timeout 5 https://ipv4.icanhazip.com || curl -s --connect-timeout 5 https://api.ipify.org
}

get_public_ipv6() { 
    curl -s --connect-timeout 5 https://ipv6.icanhazip.com || curl -s --connect-timeout 5 https://api6.ipify.org
}

get_local_ipv4() {
    ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | sort -u
}

get_local_ipv6() {
    ip -6 addr show 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-fA-F:]+' | grep -v '^::1$' | grep -v '^fe80:' | sort -u
}

resolve_ipv4() { 
    dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
}

resolve_ipv6() { 
    dig +short AAAA "$DOMAIN" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$'
}

check_dns() {
    check_dependency dig dnsutils
    check_dependency ip iproute2
    
    echo "=== 获取本机IP地址 ==="
    local public_ipv4
    local public_ipv6
    local local_ipv4_list
    local local_ipv6_list
    
    public_ipv4=$(get_public_ipv4)
    public_ipv6=$(get_public_ipv6)
    readarray -t local_ipv4_list < <(get_local_ipv4)
    readarray -t local_ipv6_list < <(get_local_ipv6)
    
    echo "外网IPv4: ${public_ipv4:-未获取到}"
    echo "外网IPv6: ${public_ipv6:-未获取到}"
    
    if [[ ${#local_ipv4_list[@]} -gt 0 ]]; then
        echo "本机IPv4地址列表:"
        for i in "${!local_ipv4_list[@]}"; do
            echo "  [$((i+1))] ${local_ipv4_list[$i]}"
        done
    fi
    
    if [[ ${#local_ipv6_list[@]} -gt 0 ]]; then
        echo "本机IPv6地址列表:"
        for i in "${!local_ipv6_list[@]}"; do
            echo "  [$((i+1))] ${local_ipv6_list[$i]}"
        done
    fi
    
    echo ""
    echo "=== 域名解析检查 ==="
    local dns_ipv4_list
    local dns_ipv6_list
    
    readarray -t dns_ipv4_list < <(resolve_ipv4)
    readarray -t dns_ipv6_list < <(resolve_ipv6)
    
    if [[ ${#dns_ipv4_list[@]} -gt 0 ]]; then
        echo "域名解析IPv4地址:"
        for ip in "${dns_ipv4_list[@]}"; do
            echo "  - $ip"
        done
    else
        echo "域名解析IPv4: 未解析到"
    fi
    
    if [[ ${#dns_ipv6_list[@]} -gt 0 ]]; then
        echo "域名解析IPv6地址:"
        for ip in "${dns_ipv6_list[@]}"; do
            echo "  - $ip"
        done
    else
        echo "域名解析IPv6: 未解析到"
    fi
    
    echo ""
    echo "=== 验证IP匹配 ==="
    
    # 创建所有本机IP的数组
    local all_local_ips=()
    [[ -n "$public_ipv4" ]] && all_local_ips+=("$public_ipv4")
    [[ -n "$public_ipv6" ]] && all_local_ips+=("$public_ipv6")
    all_local_ips+=("${local_ipv4_list[@]}")
    all_local_ips+=("${local_ipv6_list[@]}")
    
    # 检查是否有IP匹配
    local matched_ips=()
    for dns_ip in "${dns_ipv4_list[@]}" "${dns_ipv6_list[@]}"; do
        for local_ip in "${all_local_ips[@]}"; do
            if [[ "$dns_ip" == "$local_ip" ]]; then
                matched_ips+=("$dns_ip")
                break
            fi
        done
    done
    
    if [[ ${#matched_ips[@]} -gt 0 ]]; then
        echo "✅ 找到匹配的IP地址:"
        for ip in "${matched_ips[@]}"; do
            echo "  - $ip"
        done
        echo "域名解析验证通过，继续执行"
        return 0
    else
        echo "❌ 域名解析的IP地址与本机不匹配"
        
        if [[ ${#dns_ipv4_list[@]} -gt 0 || ${#dns_ipv6_list[@]} -gt 0 ]]; then
            echo ""
            echo "是否要手动验证IP匹配？"
            echo "1. 跳过验证，强制继续"
            echo "2. 重新检查DNS解析"
            echo "3. 退出脚本"
            
            read -p "请选择 [1-3]: " choice
            case $choice in
                1)
                    echo "⚠️  跳过DNS验证，强制继续执行"
                    return 0
                    ;;
                2)
                    echo "重新检查DNS解析..."
                    return 1
                    ;;
                3)
                    echo "退出脚本"
                    exit 0
                    ;;
                *)
                    echo "无效选择，默认重新检查"
                    return 1
                    ;;
            esac
        fi
        
        print_error "域名未解析到本机，请检查DNS配置！"
        echo "[建议] 请确保域名解析到以下任意一个IP:"
        for ip in "${all_local_ips[@]}"; do
            echo "  - $ip"
        done
        echo ""
        echo "你可以尝试："
        echo "1. 刷新DNS缓存"
        echo "2. 等待DNS生效（通常需要几分钟到几小时）"
        echo "3. 检查域名解析配置是否正确"
        return 1
    fi
}

check_and_open_firewall_port() {
    PORT=$1
    echo "检测端口 $PORT 的防火墙规则..."
    
    # 检查 firewalld
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        if ! command -v firewall-cmd &>/dev/null; then
            check_dependency firewall-cmd firewalld
        fi
        
        if firewall-cmd --query-port="${PORT}/tcp" &>/dev/null; then
            echo "✅ firewalld 已经开放端口 $PORT"
            return 0
        fi
        
        echo "❌ firewalld 未开放端口 $PORT"
        read -p "是否自动放行该端口？[Y/N]: " yn
        case $yn in
            [Yy]* )
                firewall-cmd --permanent --add-port="${PORT}/tcp" 2>>"$err_log"
                firewall-cmd --reload 2>>"$err_log"
                if [[ $? -ne 0 ]]; then
                    print_error "firewalld 操作失败！" "$err_log"
                    exit 1
                fi
                echo "✅ 已通过 firewalld 放行端口 $PORT"
                ;;
            * )
                print_error "请手动放行端口 $PORT，脚本退出。"
                exit 1
                ;;
        esac
        return 0
    fi
    
    # 检查 ufw
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        if ufw status | grep -w "$PORT" | grep -w "ALLOW" >/dev/null; then
            echo "✅ ufw 已经开放端口 $PORT"
            return 0
        fi
        
        echo "❌ ufw 未开放端口 $PORT"
        read -p "是否自动放行该端口？[Y/N]: " yn
        case $yn in
            [Yy]* )
                ufw allow "$PORT/tcp" 2>>"$err_log"
                if [[ $? -ne 0 ]]; then
                    print_error "ufw 操作失败！" "$err_log"
                    exit 1
                fi
                echo "✅ 已通过 ufw 放行端口 $PORT"
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
        if iptables -L INPUT -n 2>/dev/null | grep "dpt:$PORT" | grep ACCEPT >/dev/null; then
            echo "✅ iptables 已经开放端口 $PORT"
            return 0
        fi
        
        echo "❌ iptables 未开放端口 $PORT"
        read -p "是否自动放行该端口？[Y/N]: " yn
        case $yn in
            [Yy]* )
                iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>>"$err_log"
                if command -v service >/dev/null 2>&1; then
                    service iptables save 2>/dev/null
                elif command -v iptables-save >/dev/null 2>&1; then
                    iptables-save > /etc/iptables.rules 2>/dev/null
                fi
                echo "✅ 已通过 iptables 放行端口 $PORT"
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
    check_dependency lsof lsof
    check_dependency fuser psmisc
    
    if lsof -i ":$PORT" &>/dev/null; then
        echo "⚠️  端口 $PORT 被以下进程占用："
        lsof -i ":$PORT"
        read -p "是否释放该端口？[Y/N]: " yn
        case $yn in
            [Yy]* )
                fuser -k "${PORT}/tcp" 2>>"$err_log"
                sleep 2
                if lsof -i ":$PORT" &>/dev/null; then
                    print_error "端口 $PORT 释放失败，仍被占用！" "$err_log"
                    exit 1
                fi
                echo "✅ 已释放端口 $PORT"
                ;;
            * )
                print_error "请先手动释放端口 $PORT，脚本退出。"
                exit 1
                ;;
        esac
    else
        echo "✅ 端口 $PORT 未被占用"
    fi
}

error_handler() {
    print_error "检测或执行失败，自动修复中…"
    sleep 2
    rm -rf ~/.acme.sh/"$DOMAIN" 2>>"$err_log"
    sleep 2
}

install_acme() {
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        echo "✅ acme.sh 已安装"
        return 0
    fi
    
    echo "[排错] 未检测到 acme.sh，尝试自动安装..."
    curl -s https://get.acme.sh | sh -s email="$EMAIL" >>"$err_log" 2>&1
    
    if [[ $? -ne 0 ]]; then
        print_error "acme.sh 安装失败！" "$err_log"
        exit 1
    fi
    
    # 重新加载环境变量
    source ~/.bashrc 2>/dev/null || true
    
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        print_error "acme.sh 安装验证失败！"
        exit 1
    fi
    
    echo "✅ acme.sh 安装成功"
}

acme_apply() {
    check_dependency curl curl
    
    install_acme
    
    check_and_open_firewall_port "$SERVICE_PORT"
    show_port_info "$SERVICE_PORT"
    show_port_info 443
    
    echo "开始申请 SSL 证书..."
    
    # 注册账户
    ~/.acme.sh/acme.sh --register-account -m "$EMAIL" >>"$err_log" 2>&1
    
    # 申请证书
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --httpport "$SERVICE_PORT" --force >>"$err_log" 2>&1
    
    if [[ $? -eq 0 ]]; then
        echo -e "\033[32m✅ 证书申请成功！文件在 ~/.acme.sh/$DOMAIN\033[0m"
        
        echo "证书文件："
        echo "  - 证书文件: ~/.acme.sh/$DOMAIN/$DOMAIN.cer"
        echo "  - 私钥文件: ~/.acme.sh/$DOMAIN/$DOMAIN.key"
        echo "  - 完整链: ~/.acme.sh/$DOMAIN/fullchain.cer"
        
        # 检查并添加自动续期任务
        if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
            echo "添加 acme.sh 自动续期任务..."
            (crontab -l 2>/dev/null; echo "0 2 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null 2>&1") | crontab -
            echo "✅ 自动续期任务已添加"
        else
            echo "✅ 自动续期任务已存在"
        fi
    else
        print_error "acme.sh 证书签发失败！" "$err_log"
        echo "[建议] 常见原因包括：端口未放行、端口被占用、域名未正确解析到服务器。"
        return 1
    fi
}

main() {
    echo "=== SSL 证书申请脚本 ==="
    echo "域名: $DOMAIN"
    echo "邮箱: $EMAIL"
    echo "端口: $SERVICE_PORT"
    echo "========================"
    
    check_params
    check_network
    check_dependency curl curl
    
    while (( RETRY < MAX_RETRY )); do
        echo "尝试第 $((RETRY + 1)) 次..."
        
        if check_dns "$DOMAIN"; then
            if acme_apply; then
                echo "🎉 SSL 证书申请完成！"
                exit 0
            fi
        else
            error_handler
        fi
        
        ((RETRY++))
        if (( RETRY < MAX_RETRY )); then
            echo "等待 10 秒后重试..."
            sleep 10
        fi
    done
    
    print_error "❌ 多次重试失败，请手动检查并参考上面错误提示！" "$err_log"
    echo ""
    echo "常见解决方案："
    echo "1. 检查域名是否正确解析到服务器IP"
    echo "2. 确保防火墙已放行端口 $SERVICE_PORT 和 443"
    echo "3. 确保端口未被其他程序占用"
    echo "4. 检查网络连接是否正常"
    exit 1
}

main
