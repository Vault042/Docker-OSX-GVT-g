#!/usr/bin/env bash
# 用法: ./mon.sh "info pci"
# 向容器内 QEMU monitor 发送命令。个人参数来自 config.env。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/config.env}"
[[ -f "$CONFIG" ]] && source "$CONFIG"
: "${CONTAINER_NAME:=macos-gvt}"

docker exec "$CONTAINER_NAME" python3 -c "
import socket,sys,time
s=socket.socket(socket.AF_UNIX)
s.connect('/tmp/qemu-mon.sock')
time.sleep(0.3)
try: s.recv(65536)
except BlockingIOError: pass
s.sendall((sys.argv[1]+'\n').encode())
time.sleep(1)
data=b''
s.settimeout(2)
try:
    while True:
        chunk=s.recv(65536)
        if not chunk: break
        data+=chunk
except Exception: pass
print(data.decode(errors='replace'))
" "$1"
