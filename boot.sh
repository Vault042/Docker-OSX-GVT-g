#!/usr/bin/env bash
set -euo pipefail

# Docker-OSX + Intel GVT-g vGPU passthrough (Docker variant, see README §11)
# All personal values come from config.env (see config.env.example).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/config.env}"
if [[ ! -f "$CONFIG" ]]; then
  echo "缺少 $CONFIG —— 请先 cp config.env.example config.env 并填写。" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${OSX_KVM_DIR:=$HOME/OSX-KVM}"
: "${DOCKER_IMAGE:=sickcodes/docker-osx:ventura}"
: "${CONTAINER_NAME:=macos-gvt}"
: "${MDEV_TYPE:=i915-GVTg_V5_8}"
: "${RAM:=8}"
: "${SMP:=8}"
: "${CORES:=4}"
: "${SERIAL_PORT:=4444}"
: "${SSH_PORT:=10022}"
: "${VNC_PORT:=5900}"
: "${DRI_CARD:=/dev/dri/card1}"
: "${DRI_RENDER:=/dev/dri/renderD128}"
: "${SCRATCH_DIR:=/tmp/docker-osx-gvt}"
: "${VGPU_ADDR:=06.0}"

if [[ -z "${MDEV_UUID:-}" || -z "${IGPU_BDF:-}" ]]; then
  echo "config.env 未设置 MDEV_UUID / IGPU_BDF" >&2; exit 1
fi
if [[ -z "${I915_ROM:-}" || ! -f "${I915_ROM:-}" ]]; then
  echo "config.env 的 I915_ROM 不存在(Docker 变体需要 i915ovmf.rom,见 README §11)" >&2; exit 1
fi
mkdir -p "$SCRATCH_DIR"

# mdev 必须存在(可由 setup-gvt.service 开机创建)
if [[ ! -d /sys/bus/mdev/devices/$MDEV_UUID ]]; then
  echo "mdev $MDEV_UUID 不存在,尝试创建..."
  echo "$MDEV_UUID" | sudo tee "/sys/bus/mdev_bus/$IGPU_BDF/mdev_supported_types/$MDEV_TYPE/create" >/dev/null
fi

# vGPU 所在 VFIO 组
GROUP=$(basename "$(readlink /sys/bus/mdev/devices/$MDEV_UUID/iommu_group)")
echo "vGPU VFIO group: $GROUP"

# XWayland 认证文件(每次登录会话名字不同)
XAUTH_HOST=$(ls "/run/user/$(id -u)/.mutter-Xwaylandauth."* 2>/dev/null | head -1 || true)
if [[ -z "$XAUTH_HOST" ]]; then
  echo "警告: 未找到 XWayland 认证文件,QEMU 窗口可能无法显示" >&2
  XAUTH_ARGS=()
else
  XAUTH_ARGS=(-v "$XAUTH_HOST:/root/.Xauthority:ro" -e XAUTHORITY=/root/.Xauthority)
fi

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -dit \
  --name "$CONTAINER_NAME" \
  --network host \
  --user root \
  --device /dev/kvm \
  --device /dev/snd \
  --device "$DRI_CARD" \
  --device "$DRI_RENDER" \
  --device /dev/vfio/vfio \
  --device "/dev/vfio/$GROUP" \
  -v /sys/bus/mdev/devices:/sys/bus/mdev/devices:ro \
  -v "$OSX_KVM_DIR/mac_hdd_ng.img:/home/arch/OSX-KVM/mac_hdd_ng.img" \
  -v "$SCRIPT_DIR/OpenCore.qcow2:/home/arch/OSX-KVM/OpenCore/OpenCore.qcow2" \
  -v "$OSX_KVM_DIR/OVMF_CODE.fd:/home/arch/OSX-KVM/OVMF_CODE.fd:ro" \
  -v "$SCRIPT_DIR/OVMF_VARS.fd:/home/arch/OSX-KVM/OVMF_VARS-1024x768.fd" \
  -v "$I915_ROM:/home/arch/i915ovmf.rom:ro" \
  -v "$SCRATCH_DIR:/vmlogs" \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  "${XAUTH_ARGS[@]}" \
  -e DISPLAY=:0 \
  -e RAM="$RAM" \
  -e SMP="$SMP" \
  -e CORES="$CORES" \
  -e AUDIO_DRIVER=alsa \
  -e INTERNAL_SSH_PORT="$SSH_PORT" \
  -e SCREEN_SHARE_PORT="$VNC_PORT" \
  -e EXTRA="-display gtk,gl=on -monitor unix:/tmp/qemu-mon.sock,server,nowait -serial tcp:0.0.0.0:$SERIAL_PORT,server,nowait -device vfio-pci,sysfsdev=/sys/bus/mdev/devices/$MDEV_UUID,addr=$VGPU_ADDR,display=on,x-igd-opregion=on,romfile=/home/arch/i915ovmf.rom" \
  --entrypoint /bin/bash \
  "$DOCKER_IMAGE" \
  -c "./enable-ssh.sh && exec ./Launch.sh"

echo "容器已启动: $CONTAINER_NAME"
echo "  查看日志:   docker logs -f $CONTAINER_NAME"
echo "  QEMU 监视器: docker attach $CONTAINER_NAME   (Ctrl-P Ctrl-Q 分离)"
echo "  SSH 进 macOS: ssh -p $SSH_PORT localhost (需 macOS 已开启远程登录)"
