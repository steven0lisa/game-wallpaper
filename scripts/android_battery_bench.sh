#!/bin/bash
# Battery benchmark for the wallpaper: /proc/<pid>/stat jiffies over a fixed
# window while the screen is kept awake (wallpaper visible on the home screen).
#
#   ./scripts/android_battery_bench.sh <package> <label> [seconds]
#
# Requires adb over TCP (device unplugged or not) — wakes the screen with
# `cmd power wakeup` every 45 s (screen-off timeout here is 60 s and MIUI blocks
# `svc power stayon` without WRITE_SECURE_SETTINGS).
set -uo pipefail
SERIAL="${ANDROID_SERIAL:-10.13.232.184:5555}"
PKG="${1:?package}"; LABEL="${2:?label}"; SECS="${3:-300}"
ADB="adb -s $SERIAL"

$ADB shell cmd power wakeup
( while true; do $ADB shell cmd power wakeup >/dev/null 2>&1; sleep 45; done ) & KP=$!
trap 'kill $KP 2>/dev/null' EXIT
sleep 3
$ADB shell am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1

PID=$($ADB shell pidof "$PKG" | tr -d '\r')
if [ -z "$PID" ]; then echo "FAIL: no pid for $PKG"; exit 1; fi
read_stat() { $ADB shell "cat /proc/$PID/stat" 2>/dev/null | awk '{print $14+$15}'; }
awake()     { $ADB shell "dumpsys power | grep -c mWakefulness=Awake" | tr -d '\r'; }

S0=$(read_stat); T0=$(date +%s); MISS=0
while [ $(( $(date +%s) - T0 )) -lt "$SECS" ]; do
  [ "$(awake)" != "1" ] && MISS=$((MISS+1))
  sleep 30
done
S1=$(read_stat); T1=$(date +%s)

DT=$((T1-T0)); J=$((S1-S0))
CPU=$(python3 -c "print('%.2f' % ($J/(100.0*$DT)*100))")
RSS=$($ADB shell "grep VmRSS /proc/$PID/status" 2>/dev/null | tr -d '\r' | awk '{print $2" "$3}')
echo "[$LABEL] cpu=${CPU}% over ${DT}s (jiffies=$J, doze_misses=$MISS) rss=${RSS:-?}"
