#!/usr/bin/env bash
# 用法: ./set-res.sh <宽x高|Max>   例: ./set-res.sh 1920x1080
# 修改 OpenCore 的 UEFI Output Resolution,下次启动生效。
# macOS 对虚拟显卡无原生驱动(EFI 帧缓冲),系统内不能热切换分辨率,
# 这是目前唯一可靠的"自由选择"方式。
# 个人参数来自 config.env(见 config.env.example)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/config.env}"
if [[ ! -f "$CONFIG" ]]; then
  echo "缺少 $CONFIG —— 请先 cp config.env.example config.env 并填写。" >&2; exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${OSX_KVM_DIR:=$HOME/OSX-KVM}"
: "${DOCKER_IMAGE:=sickcodes/docker-osx:ventura}"
: "${VM_DOMAIN:=macOS}"
: "${SCRATCH_DIR:=/tmp/docker-osx-gvt}"

RES=${1:-Max}
case "$RES" in
  Max|max) RES=Max ;;
  [0-9]*x[0-9]*) ;;
  *) echo "参数形如 1920x1080 或 Max"; exit 1 ;;
esac

if virsh -c qemu:///system list --name 2>/dev/null | grep -qx "$VM_DOMAIN"; then
  echo "$VM_DOMAIN 正在运行,请先关机: virsh -c qemu:///system shutdown $VM_DOMAIN (或虚拟机内关机)"
  exit 1
fi

mkdir -p "$SCRATCH_DIR"
docker run --rm --network=host --user root --device /dev/kvm \
  -e LIBGUESTFS_DEBUG= -e LIBGUESTFS_TRACE= \
  -v "$OSX_KVM_DIR":/osxkvm -v "$SCRATCH_DIR":/scratch -v "$SCRATCH_DIR"/guestfs-cache:/var/tmp \
  --entrypoint sh "$DOCKER_IMAGE" -c "
set -e
guestfish --rw -a /osxkvm/OpenCore/OpenCore.qcow2 <<EOF
run
mount /dev/sda1 /
download /EFI/OC/config.plist /scratch/cur.plist
EOF
python3 - /scratch/cur.plist '$RES' <<'PY'
import plistlib, sys
path, res = sys.argv[1], sys.argv[2]
p = plistlib.load(open(path, 'rb'))
p['UEFI']['Output']['Resolution'] = res
plistlib.dump(p, open(path, 'wb'))
print('Resolution ->', res)
PY
guestfish --rw -a /osxkvm/OpenCore/OpenCore.qcow2 <<EOF
run
mount /dev/sda1 /
upload /scratch/cur.plist /EFI/OC/config.plist
EOF
"
echo "已设置分辨率 $RES,启动 VM 后生效。"
