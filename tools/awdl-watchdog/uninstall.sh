#!/bin/sh
# Removes the AWDL watchdog completely.
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "需要管理员权限，请这样运行：" >&2
    echo "  sudo sh \"$0\"" >&2
    exit 1
fi

launchctl bootout system/com.local.awdl-watchdog 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.local.awdl-watchdog.plist
rm -f /usr/local/bin/awdl-watchdog.sh
rm -f /var/tmp/awdl-watchdog.state
echo "已卸载。日志保留在 /var/log/awdl-watchdog.log，可自行删除。"
