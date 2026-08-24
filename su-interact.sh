#!/bin/bash
# 单用户串口交互:等待 shell 提示符后发送命令(调试用,见 README §10)。
# 个人参数来自 config.env。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/config.env}"
[[ -f "$CONFIG" ]] && source "$CONFIG"
: "${SCRATCH_DIR:=/tmp/docker-osx-gvt}"
: "${SERIAL_PORT:=4444}"
mkdir -p "$SCRATCH_DIR"

LOG="$SCRATCH_DIR/su.log"
rm -f "$LOG"
for i in $(seq 1 60); do
  if exec 9<>"/dev/tcp/127.0.0.1/$SERIAL_PORT" 2>/dev/null; then break; fi
  sleep 2
done
echo "connected after ~$((i*2))s"
# 后台读
( cat <&9 > "$LOG" 2>/dev/null ) &
RPID=$!
sleep 5
send() { printf '%s\n' "$1" >&9; sleep "${2:-4}"; }
send "" 3
send "kmutil showloaded 2>/dev/null | grep -i -e lilu -e whatever -e KBL -e SKL -e Graphics" 6
send "ioreg -rc IOAccelerator 2>/dev/null | head -20" 5
send "ioreg -rn IGPU 2>/dev/null | grep -e class -e name -e device-id -e model | head -10" 5
send "system_profiler SPDisplaysDataType 2>/dev/null | head -40" 12
send "exit" 2
sleep 2
kill $RPID 2>/dev/null
echo "=== CAPTURE ==="
cat "$LOG"
