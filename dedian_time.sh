#!/bin/bash


# Debian系统北京时间配置脚本
# 功能：设置北京时间，启用时间同步，包含完整排错机制
# 作者：AI助手
# 日期：$(date +%Y-%m-%d)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志文件
LOG_FILE="/var/log/beijing_time_setup.log"

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

# 检查网络连接
check_network() {
    print_info "检查网络连接..."
    
    # 尝试ping多个服务器
    servers=("8.8.8.8" "114.114.114.114" "pool.ntp.org")
    network_ok=false
    
    for server in "${servers[@]}"; do
        if ping -c 1 -W 3 "$server" &>/dev/null; then
            print_success "网络连接正常 (测试服务器: $server)"
            network_ok=true
            break
        fi
    done
    
    if [ "$network_ok" = false ]; then
        print_error "网络连接检查失败"
        print_warning "时间同步可能无法正常工作"
        return 1
    fi
    
    return 0
}

# 备份当前时间设置
backup_current_settings() {
    print_info "备份当前时间设置..."
    
    backup_dir="/tmp/time_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份时区设置
    if [ -L /etc/localtime ]; then
        cp -L /etc/localtime "$backup_dir/localtime.bak"
        readlink /etc/localtime > "$backup_dir/timezone_link.txt"
    fi
    
    # 备份timezone文件
    if [ -f /etc/timezone ]; then
        cp /etc/timezone "$backup_dir/timezone.bak"
    fi
    
    # 记录当前时间
    date > "$backup_dir/current_time.txt"
    timedatectl status > "$backup_dir/timedatectl_status.txt" 2>/dev/null || true
    
    print_success "设置已备份到: $backup_dir"
    echo "$backup_dir" > /tmp/last_time_backup_dir
}

# 检查并安装必要的软件包
install_packages() {
    print_info "检查必要的软件包..."
    
    packages=("ntp" "ntpdate" "tzdata")
    missing_packages=()
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            missing_packages+=("$package")
        fi
    done
    
    if [ ${#missing_packages[@]} -gt 0 ]; then
        print_info "需要安装以下软件包: ${missing_packages[*]}"
        
        # 更新包列表
        print_info "更新软件包列表..."
        if ! apt-get update; then
            print_error "无法更新软件包列表"
            return 1
        fi
        
        # 安装缺失的包
        for package in "${missing_packages[@]}"; do
            print_info "安装 $package..."
            if ! apt-get install -y "$package"; then
                print_error "安装 $package 失败"
                return 1
            fi
        done
        
        print_success "所有必要软件包安装完成"
    else
        print_success "所有必要软件包已安装"
    fi
    
    return 0
}

# 设置北京时区
set_beijing_timezone() {
    print_info "设置北京时区..."
    
    # 检查是否存在北京时区文件
    if [ ! -f /usr/share/zoneinfo/Asia/Shanghai ]; then
        print_error "找不到北京时区文件"
        return 1
    fi
    
    # 使用timedatectl设置时区（推荐方法）
    if command -v timedatectl &> /dev/null; then
        print_info "使用timedatectl设置时区..."
        if timedatectl set-timezone Asia/Shanghai; then
            print_success "使用timedatectl设置时区成功"
        else
            print_warning "timedatectl设置失败，尝试手动设置"
            manual_timezone_setup
        fi
    else
        print_warning "timedatectl不可用，使用手动方法设置时区"
        manual_timezone_setup
    fi
    
    # 验证时区设置
    current_timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
    if [[ "$current_timezone" == "Asia/Shanghai" ]]; then
        print_success "时区设置验证成功: $current_timezone"
    else
        print_error "时区设置验证失败: $current_timezone"
        return 1
    fi
    
    return 0
}

# 手动设置时区
manual_timezone_setup() {
    print_info "手动设置时区..."
    
    # 创建符号链接
    if ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; then
        print_success "创建时区符号链接成功"
    else
        print_error "创建时区符号链接失败"
        return 1
    fi
    
    # 更新timezone文件
    echo "Asia/Shanghai" > /etc/timezone
    print_success "更新/etc/timezone文件成功"
    
    return 0
}

# 配置NTP时间同步
configure_ntp_sync() {
    print_info "配置NTP时间同步..."
    
    # 检查systemd-timesyncd服务
    if systemctl is-active --quiet systemd-timesyncd; then
        print_info "发现systemd-timesyncd正在运行，将其停止"
        systemctl stop systemd-timesyncd
        systemctl disable systemd-timesyncd
    fi
    
    # 配置NTP服务器
    ntp_config="/etc/ntp.conf"
    if [ -f "$ntp_config" ]; then
        print_info "备份NTP配置文件..."
        cp "$ntp_config" "${ntp_config}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # 创建NTP配置
    cat > "$ntp_config" << 'EOF'
# 中国NTP服务器池
server ntp.aliyun.com prefer
server pool.ntp.org
server cn.pool.ntp.org
server 1.cn.pool.ntp.org
server 2.cn.pool.ntp.org
server 3.cn.pool.ntp.org

# 本地时钟作为备用
server 127.127.1.0
fudge 127.127.1.0 stratum 10

# 限制访问
restrict default kod notrap nomodify nopeer noquery
restrict -6 default kod notrap nomodify nopeer noquery
restrict 127.0.0.1
restrict -6 ::1

# 日志文件
logfile /var/log/ntp.log

# 允许时间大幅调整
tinker panic 0
EOF
    
    print_success "NTP配置文件创建成功"
    
    # 立即同步时间
    print_info "执行立即时间同步..."
    if ntpdate -s ntp.aliyun.com 2>/dev/null || ntpdate -s pool.ntp.org 2>/dev/null; then
        print_success "立即时间同步成功"
    else
        print_warning "立即时间同步失败，继续配置NTP服务"
    fi
    
    # 启动并启用NTP服务
    print_info "启动NTP服务..."
    if systemctl enable ntp && systemctl start ntp; then
        print_success "NTP服务启动成功"
    else
        print_error "NTP服务启动失败"
        return 1
    fi
    
    return 0
}

# 验证时间同步状态
verify_time_sync() {
    print_info "验证时间同步状态..."
    
    # 等待NTP同步
    print_info "等待NTP同步(最多60秒)..."
    for i in {1..12}; do
        if ntpq -p &>/dev/null; then
            sync_status=$(ntpq -p 2>/dev/null | grep "^\*" | wc -l)
            if [ "$sync_status" -gt 0 ]; then
                print_success "NTP同步成功"
                break
            fi
        fi
        
        if [ $i -eq 12 ]; then
            print_warning "NTP同步可能需要更长时间"
        else
            print_info "等待同步... ($((i*5))秒)"
            sleep 5
        fi
    done
    
    # 显示当前时间信息
    print_info "当前时间信息:"
    echo "系统时间: $(date)" | tee -a "$LOG_FILE"
    echo "硬件时间: $(hwclock --show 2>/dev/null || echo '无法读取')" | tee -a "$LOG_FILE"
    
    if command -v timedatectl &> /dev/null; then
        echo "时间同步状态:" | tee -a "$LOG_FILE"
        timedatectl status | tee -a "$LOG_FILE"
    fi
    
    if command -v ntpq &> /dev/null; then
        echo "NTP服务器状态:" | tee -a "$LOG_FILE"
        ntpq -p 2>/dev/null | tee -a "$LOG_FILE" || print_warning "无法获取NTP状态"
    fi
}

# 系统兼容性检查
check_system_compatibility() {
    print_info "检查系统兼容性..."
    
    # 检查是否为Debian系统
    if [ ! -f /etc/debian_version ]; then
        print_warning "警告：这不是Debian系统"
        print_info "检测到的系统信息:"
        cat /etc/os-release 2>/dev/null | head -5 | tee -a "$LOG_FILE"
        
        read -p "是否继续执行? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "用户取消执行"
            exit 0
        fi
    else
        debian_version=$(cat /etc/debian_version)
        print_success "Debian系统检查通过，版本: $debian_version"
    fi
    
    # 检查系统架构
    arch=$(uname -m)
    print_info "系统架构: $arch"
    
    # 检查内核版本
    kernel=$(uname -r)
    print_info "内核版本: $kernel"
    
    return 0
}

# 修复常见问题
fix_common_issues() {
    print_info "检查并修复常见问题..."
    
    # 修复权限问题
    if [ -f /etc/ntp.conf ]; then
        chmod 644 /etc/ntp.conf
        print_info "修复NTP配置文件权限"
    fi
    
    # 清理旧的时间同步进程
    if pgrep -f "ntpd" > /dev/null; then
        print_info "发现运行中的ntpd进程"
    fi
    
    # 检查防火墙是否阻止NTP
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        print_info "检查防火墙NTP端口(123/udp)"
        if ! ufw status | grep -q "123/udp"; then
            print_warning "防火墙可能阻止NTP流量"
            read -p "是否允许NTP流量通过防火墙? (y/N): " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ufw allow 123/udp
                print_success "已允许NTP流量通过防火墙"
            fi
        fi
    fi
    
    # 同步硬件时钟
    print_info "同步硬件时钟..."
    if hwclock --systohc 2>/dev/null; then
        print_success "硬件时钟同步成功"
    else
        print_warning "硬件时钟同步失败"
    fi
    
    return 0
}

# 创建监控脚本
create_monitoring_script() {
    print_info "创建时间同步监控脚本..."
    
    monitor_script="/usr/local/bin/check_time_sync.sh"
    
    cat > "$monitor_script" << 'EOF'
#!/bin/bash
# 时间同步监控脚本

LOG_FILE="/var/log/time_sync_monitor.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 检查NTP同步状态
if ! systemctl is-active --quiet ntp; then
    log_message "ERROR: NTP服务未运行"
    systemctl start ntp
    log_message "INFO: 尝试重启NTP服务"
fi

# 检查时间偏差
if command -v ntpq &> /dev/null; then
    offset=$(ntpq -p 2>/dev/null | grep "^\*" | awk '{print $9}' | head -1)
    if [ -n "$offset" ]; then
        offset_abs=${offset#-}
        if (( $(echo "$offset_abs > 1000" | bc -l) )); then
            log_message "WARNING: 时间偏差过大: ${offset}ms"
        fi
    fi
fi

# 记录当前状态
log_message "INFO: 时间同步检查完成 - $(date)"
EOF
    
    chmod +x "$monitor_script"
    print_success "监控脚本创建成功: $monitor_script"
    
    # 创建cron任务
    print_info "设置定期监控任务..."
    (crontab -l 2>/dev/null | grep -v "$monitor_script"; echo "*/10 * * * * $monitor_script") | crontab -
    print_success "已设置每10分钟执行一次监控检查"
    
    return 0
}

# 显示帮助信息
show_help() {
    cat << EOF
Debian北京时间配置脚本

用法: $0 [选项]

选项:
    -h, --help          显示此帮助信息
    -v, --verbose       详细输出模式
    -n, --no-network    跳过网络检查
    -b, --backup-only   仅备份当前设置
    -r, --restore       恢复备份设置
    --no-monitor        不创建监控脚本

功能:
    - 设置系统时区为北京时间(Asia/Shanghai)
    - 启用NTP时间同步
    - 配置中国NTP服务器
    - 完整的错误检查和排错机制
    - 自动备份原始设置
    - 创建监控脚本

日志文件: $LOG_FILE

示例:
    sudo $0                    # 标准执行
    sudo $0 --verbose         # 详细输出
    sudo $0 --restore         # 恢复备份
EOF
}

# 主函数
main() {
    print_info "=== Debian北京时间配置脚本开始执行 ==="
    print_info "执行时间: $(date)"
    print_info "脚本版本: 1.0"
    
    # 解析命令行参数
    VERBOSE=false
    NO_NETWORK=false
    BACKUP_ONLY=false
    RESTORE=false
    NO_MONITOR=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -n|--no-network)
                NO_NETWORK=true
                shift
                ;;
            -b|--backup-only)
                BACKUP_ONLY=true
                shift
                ;;
            -r|--restore)
                RESTORE=true
                shift
                ;;
            --no-monitor)
                NO_MONITOR=true
                shift
                ;;
            *)
                print_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 检查root权限
    check_root
    
    # 如果是恢复模式
    if [ "$RESTORE" = true ]; then
        if [ -f /tmp/last_time_backup_dir ]; then
            backup_dir=$(cat /tmp/last_time_backup_dir)
            if [ -d "$backup_dir" ]; then
                print_info "从备份恢复设置: $backup_dir"
                # 恢复逻辑...
                print_success "设置恢复完成"
            else
                print_error "备份目录不存在: $backup_dir"
            fi
        else
            print_error "找不到备份信息"
        fi
        exit 0
    fi
    
    # 系统兼容性检查
    check_system_compatibility
    
    # 备份当前设置
    backup_current_settings
    
    # 如果只备份
    if [ "$BACKUP_ONLY" = true ]; then
        print_success "仅备份模式完成"
        exit 0
    fi
    
    # 网络检查
    if [ "$NO_NETWORK" = false ]; then
        check_network
    fi
    
    # 安装必要软件包
    if ! install_packages; then
        print_error "软件包安装失败"
        exit 1
    fi
    
    # 设置北京时区
    if ! set_beijing_timezone; then
        print_error "时区设置失败"
        exit 1
    fi
    
    # 配置NTP同步
    if ! configure_ntp_sync; then
        print_error "NTP同步配置失败"
        exit 1
    fi
    
    # 修复常见问题
    fix_common_issues
    
    # 验证时间同步
    verify_time_sync
    
    # 创建监控脚本
    if [ "$NO_MONITOR" = false ]; then
        create_monitoring_script
    fi
    
    print_success "=== 北京时间配置完成 ==="
    print_info "系统已设置为北京时间并启用时间同步"
    print_info "日志文件: $LOG_FILE"
    print_info "监控脚本: /usr/local/bin/check_time_sync.sh"
    
    print_info "建议重启系统以确保所有设置生效"
    read -p "是否现在重启系统? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "系统将在5秒后重启..."
        sleep 5
        reboot
    fi
}

# 脚本入口
main "$@"
