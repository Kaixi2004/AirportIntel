# awdl-watchdog

在系统服务层（不是 kext）自动修复「睡眠唤醒后隔空投送 / 接力突然失效」的问题。

## 它解决的问题

睡眠唤醒后，Intel 网卡驱动仍在正常发帧（`ITLAWDLCoexTxOK` 增长，失败 0），但
`ITLAWDLCoexPeerSyncFrames` 和 `ITLAWDLCoexDataRx` 都不再增长，而对端表里还留着记录
——无线停在了手机已经离开的频道上，而这个频道只有 `wifip2pd` 能重新指定。

重启 `sharingd` / `wifip2pd` 一秒即恢复。重启系统也「恢复」，所以一直误以为是驱动问题。

## 判定规则

难点在于区分「聋了」和「本来就没人发」。手机放在另一个房间时，计数特征和故障状态
**完全一样**，所以判定不能只看计数：

| 顺序 | 条件 | 说明 |
|---|---|---|
| 1 | `awdl0` 必须 UP+RUNNING | 否则没有可修对象；接口闪断时只更新时间戳，不算睡醒 |
| 2 | 首次运行（新装或刚开机）只记基线 | 否则「一直没收到帧」会被误算成活过一次 |
| 3 | 接收计数（sync + data）在增长 | 链路活着 → 清零停顿计时与重试预算，标记「本会话听到过对端」 |
| 4 | 用户空闲 < 5 分钟 | 人不在就不动，避免整夜反复重启 |
| 5 | 对端表 ≥ 1 条 | 有陈旧记录才说明「应该收得到却没收到」 |
| 6a | 刚唤醒（两次运行间隔 > 5 分钟），醒来 60 秒仍无接收 | 主触发器：睡眠前表里有对端，这就是证据 |
| 6b | **本会话听到过对端**，随后 15 分钟无接收 | 兜底触发器：先收到过再断，才是故障 |
| 7 | 每次唤醒最多 1 次；两次动作间隔 ≥ 30 分钟；本轮最多 3 次 | 防抖动 |

第 6b 条里的「本会话听到过」是关键防线：手机一整天不在旁边时 `heard` 始终为 0，
看门狗一次都不会动手。只有「本来在收、突然断了」才会触发。

动作：`killall -9 sharingd wifip2pd`。

**故意不杀 `bluetoothd`**：三个里面只有它会让人感知到（音频瞬断），而持有陈旧频道的是
另外两个。日志会记录动作前后的接收计数，若将来发现必须连蓝牙一起重启，日志会显示出来。

## 安装 / 卸载

```bash
sudo sh install.sh     # 装（重复执行即升级，会重置状态）
sudo sh uninstall.sh   # 完全卸载
```

## 查看它干过什么

```bash
tail -20 /var/log/awdl-watchdog.log
cat /var/tmp/awdl-watchdog.state
launchctl print system/com.local.awdl-watchdog | grep -E "state|runs|last exit"
```

日志里出现 `restarting sharingd/wifip2pd` 表示它动作过；紧接着若接收计数恢复增长，
说明修对了。

## 手动验证（不实际动手）

```bash
AWDL_WATCHDOG_DRY_RUN=1 AWDL_WATCHDOG_STATE=/tmp/w.state \
AWDL_LOG=/tmp/w.log sudo sh awdl-watchdog.sh
```

长时间无输出且无报错，说明当前判定为「不需要动作」。

## 可调参数

全部通过环境变量覆盖，写在 plist 的 `EnvironmentVariables` 里即可：
`AWDL_IDLE_MAX_SECS`、`AWDL_WAKE_GAP_SECS`、`AWDL_POST_WAKE_WAIT`、
`AWDL_WAKE_WINDOW`、`AWDL_STALL_SECS`、`AWDL_COOLDOWN_SECS`、`AWDL_MAX_ATTEMPTS`。
