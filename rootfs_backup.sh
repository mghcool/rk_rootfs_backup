#!/bin/bash
# RK根分区备份脚本

set -e # 当命令以非零状态退出时，则退出shell

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 配置参数
MOUNT_DIR="/mnt/rk_rootfs_backup"
# 处理备份文件路径
if [ -z "$1" ]; then
    BACKUP_FILE="${SCRIPT_DIR}/backup.img"
else
    # 如果参数是绝对路径，直接使用；如果是相对路径，转换为绝对路径
    if [[ "$1" = /* ]]; then
        BACKUP_FILE="$1"
    else
        BACKUP_FILE="${SCRIPT_DIR}/$1"
    fi
fi

# 必需软件列表
REQUIRED_CMDS=("rsync" "pigz" "pv")

# 检查root权限
[ "$(id -u)" -ne 0 ] && { echo "必须使用root权限运行！"; exit 1; }

# 软件依赖检查
check_deps() {
    local missing_pkgs=()
    
    # 检查缺失的软件包
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_pkgs+=("$cmd")
        fi
    done
    
    # 如果有缺失的软件包，统一安装
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        echo "需要安装以下软件包：${missing_pkgs[*]}"
        { command -v apt && apt update && apt install -y "${missing_pkgs[@]}"; } ||
        { command -v yum && yum install -y "${missing_pkgs[@]}"; } ||
        { command -v apk && apk add "${missing_pkgs[@]}"; } ||
        { echo "不支持的包管理器"; exit 1; }
    fi
}

# 空间计算
calc_image_size() {
    local root_dev=$(findmnt -n -o SOURCE /)
    local used_kb=$(df -B1K --output=used "$root_dev" | tail -1)
    local total_kb=$((used_kb + 204800)) # +200MB
    
    echo "$total_kb"  # 返回总 KB
}

# 安全清理
cleanup() {
    umount -l "$MOUNT_DIR" 2>/dev/null
    rm -rf "$MOUNT_DIR"
}

main() {
    echo "开始备份"
    trap cleanup EXIT
    # 检查依赖
    check_deps
    # 计算文件大小
    local total_kb=$(calc_image_size)
    local total_mb=$((total_kb / 1024))
    # 创建镜像
    echo "创建镜像文件：$BACKUP_FILE (大小：$total_mb Mb)"
    dd if=/dev/zero of="$BACKUP_FILE" bs=1K count=0 seek="$total_kb"
    # 格式化文件系统
    echo "格式化分区..."
    mkfs.ext4 -q -E lazy_itable_init=1 "$BACKUP_FILE"
    # 挂载分区
    echo "挂载分区 $MOUNT_DIR"
    mkdir -p "$MOUNT_DIR"
    mount "$BACKUP_FILE" "$MOUNT_DIR"
    echo "开始同步分区文件..."
    # 同步文件
    rsync -aHAX --sparse \
    --info=progress2 \
    --no-inc-recursive \
    --exclude="$BACKUP_FILE" \
    --exclude="$SCRIPT_DIR/$0" \
    --exclude={'/dev/*','/proc/*','/sys/*','/tmp/*','/run/*','/mnt/*','/media/*'} \
    / "$MOUNT_DIR/"
    echo "分区文件同步完成"
    # 植入首次启动自动扩容任务
    echo '@reboot root /sbin/resize2fs $(findmnt -no SOURCE /) && rm -f /etc/cron.d/resize-rootfs' > "${MOUNT_DIR}/etc/cron.d/resize-rootfs"
    chmod 600 "${MOUNT_DIR}/etc/cron.d/resize-rootfs" # 设置严格权限（600）
    # 卸载分区
    echo "卸载分区 $MOUNT_DIR"
    umount "$MOUNT_DIR"
    rm -rf "$MOUNT_DIR"
    # 询问是否压缩文件
    read -p "是否要压缩文件？(y/n): " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        pv ${BACKUP_FILE} | pigz -5 > ${BACKUP_FILE}.gz
        rm ${BACKUP_FILE}
        BACKUP_FILE=${BACKUP_FILE}.gz
    fi
        
    echo "备份完成：${BACKUP_FILE}"
}

main
