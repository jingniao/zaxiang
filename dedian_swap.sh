#!/bin/bash
 
# 检查并安装bc
if ! command -v bc &>/dev/null; then
    echo "检测到未安装bc，正在自动安装..."
    sudo apt-get update && sudo apt-get install -y bc
    if [ $? -ne 0 ]; then
        echo "自动安装bc失败，请手动执行: sudo apt-get install bc"
        exit 1
    fi
fi

# 读取用户输入的swap大小
read -p "请输入想要创建的swap大小（如2G、1.5G、2048M）: " user_input

# 格式校验与转换
if [[ $user_input =~ ^([0-9]+(\.[0-9]+)?)[GgMm]$ ]]; then
    unit="${user_input: -1}"                  # 单位G/M
    num=$(echo $user_input | sed -E 's/([GgMm])$//')
    if ! [[ $num =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "数值格式有误，请输入正数。"
        exit 1
    fi
    if [[ $unit =~ [Gg] ]]; then
        msize=$(echo "$num * 1024" | bc)
        msize_int=$(printf "%.0f" "$msize")
        swapsize="${msize_int}M"
    else
        msize=$(echo "$num" | bc)
        msize_int=$(printf "%.0f" "$msize")
        swapsize="${msize_int}M"
    fi
    if [[ $msize_int -lt 128 ]]; then
        echo "Swap太小，建议大于128M。"
        exit 1
    fi
else
    echo "输入格式不对！请用如 2G、1.5G、2048M 这样的格式。"
    exit 1
fi

echo "将创建 $swapsize 的swap..."

# 检查已有swapfile
if swapon --show | grep -q '/swapfile'; then
    echo "检测到已有/swapfile。"
    read -p "是否要覆盖已有swapfile？(y/n): " over
    if [[ $over != "y" ]]; then
        echo "已取消操作。"
        exit 0
    else
        sudo swapoff /swapfile 2>/dev/null
        sudo rm -f /swapfile
    fi
fi

# 检查磁盘空间
avail=$(df / | tail -1 | awk '{print $4}')
avail_mb=$((avail / 1024))
if [[ $avail_mb -lt $msize_int ]]; then
    echo "磁盘剩余空间不足，只剩${avail_mb}M，无法创建${msize_int}M的swap。"
    exit 1
fi

# 创建swap文件
echo "正在创建swap文件..."
sudo fallocate -l $swapsize /swapfile 2>/dev/null
if [[ $? -ne 0 ]]; then
    echo "fallocate失败，尝试dd..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=$msize_int status=progress
    if [[ $? -ne 0 ]]; then
        echo "创建swap文件失败，请检查磁盘空间。"
        exit 1
    fi
fi

# 设置权限和初始化swap
sudo chmod 600 /swapfile
sudo mkswap /swapfile
if [[ $? -ne 0 ]]; then
    echo "mkswap初始化失败，可能是swapfile创建有误。"
    sudo rm -f /swapfile
    exit 1
fi

# 启用swap
sudo swapon /swapfile
if [[ $? -ne 0 ]]; then
    echo "swapon失败，请检查/swapfile文件和权限。"
    exit 1
fi

# 写入/etc/fstab
if grep -q "^/swapfile" /etc/fstab; then
    echo "/etc/fstab已有/swapfile记录，无需重复写入。"
else
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# 最终检查
if swapon --show | grep -q '/swapfile'; then
    echo "Swap创建并永久启用成功！"
    swapon --show
    free -h
else
    echo "Swap启用失败，请手动检查。"
    exit 1
fi
