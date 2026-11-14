#!/bin/sh
# Installs the AWDL watchdog as a system daemon. Run once with sudo.
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "需要管理员权限，请这样运行：" >&2
    echo "  sudo sh \"$0\"" >&2
    exit 1
fi

DIR=$(cd "$(dirname "$0")" && pwd)
PLIST=/Library/LaunchDaemons/com.local.awdl-watchdog.plist

mkdir -p /usr/local/bin
install -m 755 -o root -g wheel "$DIR/awdl-watchdog.sh" /usr/local/bin/awdl-watchdog.sh
install -m 644 -o root -g wheel "$DIR/com.local.awdl-watchdog.plist" "$PLIST"

: >> /var/log/awdl-watchdog.log
chmod 644 /var/log/awdl-watchdog.log

launchctl bootout system/com.local.awdl-watchdog 2>/dev/null || true
rm -f /var/tmp/awdl-watchdog.state
launchctl bootstrap system "$PLIST"
launchctl enable system/com.local.awdl-watchdog

echo "已安装并启动。当前状态："
launchctl print system/com.local.awdl-watchdog 2>/dev/null | grep -E "state|program|runs|last exit" | head -6
echo
echo "日志：/var/log/awdl-watchdog.log"
echo "立即自检：sudo sh /usr/local/bin/awdl-watchdog.sh && echo 自检通过（无输出即正常）"
