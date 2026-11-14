#!/bin/sh
# awdl-watchdog: restart the AirDrop / Handoff daemons when AWDL has gone deaf.
#
# The failure this exists for: after a sleep/wake cycle the Intel Wi-Fi driver
# keeps transmitting (ITLAWDLCoexTxOK climbs, zero failures) but nothing is
# received any more -- ITLAWDLCoexPeerSyncFrames and ITLAWDLCoexDataRx both stop
# -- while ITLAWDLCoexPeerPresentEntries still lists a peer. The radio sits on a
# channel the phone has left, and only wifip2pd can ask for a new one.
# Restarting the daemons fixes it in about a second. A reboot also "fixed" it,
# which is why it looked like a driver bug.
#
# The hard part is telling "deaf" apart from "nobody is sending". A phone in
# another room produces exactly the same counters as a wedged daemon, so the
# decision never rests on the counters alone:
#
#   after a wake, the peer table still listing somebody is the evidence -- those
#   entries were real before the machine slept;
#   while awake, the evidence is that frames *were* arriving in this session and
#   then stopped. If nothing has arrived since the machine woke, a quiet AirDrop
#   is the ordinary explanation and nothing is touched.
#
# Rule, in order:
#   1. awdl0 must be up, otherwise there is nothing to fix.
#   2. First run after install or boot only records a baseline.
#   3. Received frames (sync + data) growing -> healthy, clear the stall clock,
#      the retry budget, and mark this session as having heard a peer.
#   4. The user must be at the machine (idle < 5 min), otherwise a quiet AirDrop
#      is expected and acting would only waste power overnight.
#   5. A peer must still be listed, otherwise nothing stale is being believed.
#   6. Act when either
#        a) the machine just woke (the gap between two runs exceeds 5 min) and a
#           full minute passed with nothing received, or
#        b) frames were heard in this session, then stopped for 15 minutes,
#      and at most once per wake, at most once per 30 minutes, and at most 3
#      times per boot without a single received frame in between.
#
# The action is `killall -9 sharingd wifip2pd`. bluetoothd is deliberately left
# alone: it is the only one of the three whose restart users can notice (audio
# drops), and the two AirDrop daemons are the ones holding the stale channel.
# The log records the counters at the moment of the decision, so if a future
# failure turns out to need bluetoothd as well, the log will show it.

PATH=/usr/sbin:/usr/bin:/bin:/sbin
IOLOG=${AWDL_LOG:-/var/log/awdl-watchdog.log}
STATE=${AWDL_WATCHDOG_STATE:-/var/tmp/awdl-watchdog.state}
DRY_RUN=${AWDL_WATCHDOG_DRY_RUN:-0}

IDLE_MAX_SECS=${AWDL_IDLE_MAX_SECS:-300}   # do nothing once the user is away
WAKE_GAP_SECS=${AWDL_WAKE_GAP_SECS:-300}   # a run gap this long means a sleep
POST_WAKE_WAIT=${AWDL_POST_WAKE_WAIT:-60}  # let the daemons settle after waking
WAKE_WINDOW=${AWDL_WAKE_WINDOW:-600}       # how long after waking a check counts
STALL_SECS=${AWDL_STALL_SECS:-900}         # heard something, then deaf this long
COOLDOWN_SECS=${AWDL_COOLDOWN_SECS:-1800}  # between two attempts
MAX_ATTEMPTS=${AWDL_MAX_ATTEMPTS:-3}       # per boot, without any received frame

log() {
    if [ -f "$IOLOG" ] && [ "$(wc -c < "$IOLOG" 2>/dev/null | tr -d ' ')" -gt 262144 ] 2>/dev/null; then
        : > "$IOLOG" 2>/dev/null
    fi
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" 2>/dev/null >> "$IOLOG" || true
}

num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

counters() {
    ioreg -l -w0 2>/dev/null | awk '
        /"ITLAWDLCoexPeerPresentEntries"/ { peers = $NF }
        /"ITLAWDLCoexPeerSyncFrames"/     { sync = $NF }
        /"ITLAWDLCoexDataRx"/             { rx = $NF }
        END {
            gsub(/[^0-9]/, "", peers); gsub(/[^0-9]/, "", sync); gsub(/[^0-9]/, "", rx)
            print (peers == "" ? -1 : peers), (sync == "" ? -1 : sync), (rx == "" ? -1 : rx)
        }'
}

idle_seconds() {
    n=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/"HIDIdleTime"/ { print $NF; exit }' | tr -dc '0-9')
    [ -z "$n" ] && { echo 0; return; }
    echo $((n / 1000000000))
}

# live change_ts last_kill fails acted_wake wake_ts heard last_run
save() {
    printf '%s %s %s %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$STATE"
}

# Keep the run clock honest when there is nothing to measure: awdl0 comes and
# goes with the network, and a gap must mean "the machine slept", not "the
# interface blinked".
stampd() {
    [ -f "$STATE" ] || return 0
    awk -v n="$1" 'NF == 8 { $8 = n } { print }' "$STATE" > "$STATE.tmp" 2>/dev/null &&
        mv "$STATE.tmp" "$STATE" 2>/dev/null
}

now=$(date +%s)

# --- guards ----------------------------------------------------------------

if ! ifconfig awdl0 2>/dev/null | head -1 | grep -q 'UP,.*RUNNING'; then
    stampd "$now"
    exit 0
fi

set -- $(counters)
peers=$1
sync=$2
rx=$3
[ "$sync" -lt 0 ] 2>/dev/null && { stampd "$now"; exit 0; }
[ "$rx" -lt 0 ] 2>/dev/null && { stampd "$now"; exit 0; }

live=$((sync + rx))

# First run after an install or a boot: record where we are and say nothing.
# Counting this as "a peer was heard" would make a quiet machine look broken.
if [ ! -f "$STATE" ]; then
    save "$live" "$now" 0 0 0 0 0 "$now"
    log "baseline: peers ${peers}, live ${live}"
    exit 0
fi

live0=0
change_ts=$now
last_kill=0
fails=0
acted_wake=0
wake_ts=0
heard=0
last_run=0
read -r live0 change_ts last_kill fails acted_wake wake_ts heard last_run < "$STATE" 2>/dev/null
live0=$(num "$live0" "$live")
change_ts=$(num "$change_ts" "$now")
last_kill=$(num "$last_kill" 0)
fails=$(num "$fails" 0)
acted_wake=$(num "$acted_wake" 0)
wake_ts=$(num "$wake_ts" 0)
heard=$(num "$heard" 0)
last_run=$(num "$last_run" 0)

gap=$((now - last_run))
if [ "$last_run" -gt 0 ] && [ "$gap" -gt "$WAKE_GAP_SECS" ]; then
    # The daemon did not run for a while: the machine was asleep. This is the
    # window where the link breaks, so start a fresh count from here.
    wake_ts=$now
    acted_wake=0
    change_ts=$now
    fails=0
    heard=0
    log "woke after a ${gap}s gap, watching for received frames"
fi

# Received something: the link is alive. Clear the stall clock and the budget.
if [ "$live" != "$live0" ]; then
    save "$live" "$now" "$last_kill" 0 1 "$wake_ts" 1 "$now"
    exit 0
fi

idle=$(idle_seconds)
if [ "$idle" -gt "$IDLE_MAX_SECS" ] 2>/dev/null; then
    save "$live" "$change_ts" "$last_kill" "$fails" "$acted_wake" "$wake_ts" "$heard" "$now"
    exit 0
fi

if [ "$peers" -lt 1 ]; then
    save "$live" "$change_ts" "$last_kill" "$fails" "$acted_wake" "$wake_ts" "$heard" "$now"
    exit 0
fi

stalled=$((now - change_ts))

trigger=0
reason=""
if [ "$wake_ts" -gt 0 ] && [ "$acted_wake" = "0" ]; then
    since_wake=$((now - wake_ts))
    if [ "$since_wake" -ge "$POST_WAKE_WAIT" ] && [ "$since_wake" -le "$WAKE_WINDOW" ] &&
       [ "$stalled" -ge "$POST_WAKE_WAIT" ]; then
        trigger=1
        reason="nothing received in ${stalled}s since waking ${since_wake}s ago"
    fi
fi
if [ "$trigger" = "0" ] && [ "$heard" = "1" ] && [ "$stalled" -ge "$STALL_SECS" ] &&
   [ $((now - last_kill)) -ge "$COOLDOWN_SECS" ]; then
    trigger=1
    reason="heard a peer earlier, then nothing for ${stalled}s"
fi

if [ "$trigger" = "0" ] || [ "$fails" -ge "$MAX_ATTEMPTS" ]; then
    save "$live" "$change_ts" "$last_kill" "$fails" "$acted_wake" "$wake_ts" "$heard" "$now"
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN: would restart daemons -- ${reason}, peers ${peers}, live ${live}"
    echo "would restart: ${reason}, peers=${peers} live=${live} idle=${idle}s fails=${fails} heard=${heard}"
    exit 0
fi

log "restarting sharingd/wifip2pd -- ${reason}, peers ${peers}, live ${live} (sync ${sync} rx ${rx}), attempt $((fails + 1))/${MAX_ATTEMPTS}"
killall -9 sharingd wifip2pd 2>/dev/null
save "$live" "$now" "$now" "$((fails + 1))" 1 "$wake_ts" "$heard" "$now"
log "restart issued, cooling down for ${COOLDOWN_SECS}s"
