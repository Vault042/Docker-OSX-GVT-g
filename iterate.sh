#!/usr/bin/env bash
# 用法: ./iterate.sh <devid-hex> <platformid-hex> <tag>
# 改 OpenCore 注入 -> 换盘 -> 重启容器 -> 抓串口,用于批量试验 device-id/platform-id。
# 个人参数来自 config.env(见 config.env.example)。
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/config.env}"
if [[ ! -f "$CONFIG" ]]; then
  echo "缺少 $CONFIG —— 请先 cp config.env.example config.env 并填写。" >&2; exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${DOCKER_IMAGE:=sickcodes/docker-osx:ventura}"
: "${CONTAINER_NAME:=macos-gvt}"
: "${SCRATCH_DIR:=/tmp/docker-osx-gvt}"
: "${SERIAL_PORT:=4444}"
mkdir -p "$SCRATCH_DIR"

DEVID=$1; PLATID=$2; TAG=$3
python3 - "$DEVID" "$PLATID" <<EOF
import plistlib, sys
devid=int(sys.argv[1],16); platid=int(sys.argv[2],16)
p=plistlib.load(open('$SCRATCH_DIR/oc-config.plist','rb'))
def b32(v): return v.to_bytes(4,'little')
p['DeviceProperties']['Add']['PciRoot(0x0)/Pci(0x6,0x0)']={
 'device-id': b32(devid),
 'AAPL,ig-platform-id': b32(platid),
 'framebuffer-patch-enable': b32(1),
 'framebuffer-stolenmem': b32(0x01300000),
 'framebuffer-fbmem': b32(0x00900000),
 'model': 'Intel HD Graphics (GVT-g)',
}
p['Misc']['Boot'].pop('Boot-args',None)
guid='7C436110-AB2A-4BBB-A880-FE41995C9F82'
p['NVRAM']['Add'][guid]['boot-args']='-v keepsyms=1 amfi_get_out_of_my_way=1 tlbto_us=0 vti=9 serial=3'
plistlib.dump(p,open('$SCRATCH_DIR/oc-config-patched.plist','wb'))
print('patched devid=%04x platid=%08x'%(devid,platid))
EOF
docker run --rm --network=host --user root --device /dev/kvm \
  -v "$SCRATCH_DIR":/scratch -v "$SCRATCH_DIR"/guestfs-cache:/var/tmp \
  --entrypoint sh "$DOCKER_IMAGE" -c 'guestfish --rw -a /scratch/OpenCore-work.qcow2 <<GUESTEOF
run
mount /dev/sda1 /
upload /scratch/oc-config-patched.plist /EFI/OC/config.plist
GUESTEOF' 2>&1 | grep -i "libguestfs: error" || true
docker rm -f "$CONTAINER_NAME" >/dev/null
cp "$SCRATCH_DIR/OpenCore-work.qcow2" "$SCRIPT_DIR/OpenCore.qcow2"
"$SCRIPT_DIR/boot.sh" >/dev/null
rm -f "$SCRATCH_DIR/serial-iter.log"
bash -c "sleep 2; exec 3<>/dev/tcp/127.0.0.1/$SERIAL_PORT; timeout 170 cat <&3" > "$SCRATCH_DIR/serial-iter.log" 2>/dev/null &
sleep 175
echo "=== $TAG devid=$DEVID platid=$PLATID ==="
grep -i -e "IGPU" -e "framebuffer" -e "acceleration" -e "panic" "$SCRATCH_DIR/serial-iter.log" | head -10
