#!/usr/bin/env bash
#
# setup.sh — one-shot host setup & OpenCore injection for GVT-g + macOS VM.
# Part of Docker-OSX-GVT-g (based on kholia/OSX-KVM). See README §15.
#
# Usage:
#   ./setup.sh check            verify host environment
#   ./setup.sh mdev             create the GVT-g mdev instance (sudo)
#   ./setup.sh boot-service     install systemd unit creating the mdev at boot (sudo)
#   ./setup.sh udev             install VFIO udev rules (sudo)
#   ./setup.sh snippet          generate a libvirt XML snippet for the domain
#   ./setup.sh inject [devid] [platid]
#                               inject iGPU DeviceProperties into OpenCore.qcow2
#   ./setup.sh all              check + mdev + boot-service + udev + snippet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/config.env}"
if [[ ! -f "$CONFIG" ]]; then
  echo "Missing $CONFIG — run: cp config.env.example config.env (then edit it)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${OSX_KVM_DIR:=$HOME/OSX-KVM}"
: "${DOCKER_IMAGE:=sickcodes/docker-osx:ventura}"
: "${MDEV_TYPE:=i915-GVTg_V5_8}"
: "${VM_DOMAIN:=macOS}"
: "${SCRATCH_DIR:=/tmp/docker-osx-gvt}"
: "${VGPU_ADDR:=06.0}"
[[ -n "${GUEST_MAC:-}" ]] || GUEST_MAC=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))

ok()   { printf '  [ ok ] %s\n' "$1"; }
warn() { printf '  [warn] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; }

require_mdev_vars() {
  if [[ -z "${MDEV_UUID:-}" || -z "${IGPU_BDF:-}" ]]; then
    echo "Set MDEV_UUID and IGPU_BDF in config.env first." >&2
    exit 1
  fi
}

cmd_check() {
  echo "== Host environment check =="
  grep -q ' vmx ' /proc/cpuinfo && ok "CPU supports VT-x" || fail "VT-x not available"
  local vga
  vga=$(lspci -nn 2>/dev/null | grep -i vga | head -1 || true)
  [[ -n "$vga" ]] && ok "iGPU: $vga" || warn "no VGA device found via lspci"
  if compgen -G "/sys/class/mdev_bus/*/mdev_supported_types" >/dev/null; then
    for d in /sys/class/mdev_bus/*/mdev_supported_types; do
      ok "GVT-g types on ${d%/mdev_supported_types}: $(ls "$d" | tr '\n' ' ')"
    done
  else
    fail "/sys/class/mdev_bus missing — need kernel cmdline 'intel_iommu=on iommu=pt i915.enable_gvt=1' + modprobe kvmgt (see README §3)"
  fi
  grep -q 'intel_iommu=on' /proc/cmdline && ok "intel_iommu=on in kernel cmdline" || warn "intel_iommu=on not in /proc/cmdline"
  local msrs
  msrs=$(cat /proc/sys/kernel/ignore_msrs 2>/dev/null || cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || true)
  [[ "$msrs" == "1" || "$msrs" == "Y" ]] \
    && ok "ignore_msrs enabled ($msrs)" \
    || warn "ignore_msrs not enabled (macOS needs it, see README §3.2)"
  if [[ -n "${MDEV_UUID:-}" && -d "/sys/bus/mdev/devices/${MDEV_UUID}" ]]; then
    ok "mdev $MDEV_UUID exists (VFIO group $(basename "$(readlink "/sys/bus/mdev/devices/${MDEV_UUID}/iommu_group")"))"
  else
    warn "mdev ${MDEV_UUID:-<unset>} not created yet — run: ./setup.sh mdev"
  fi
  command -v virsh >/dev/null && ok "virsh available" || warn "virsh not found (needed for the libvirt path)"
  command -v docker >/dev/null && ok "docker available" || warn "docker not found (needed by 'inject' via guestfish)"
  return 0
}

cmd_mdev() {
  require_mdev_vars
  local create="/sys/bus/mdev_bus/$IGPU_BDF/mdev_supported_types/$MDEV_TYPE/create"
  if [[ -d "/sys/bus/mdev/devices/$MDEV_UUID" ]]; then
    ok "mdev $MDEV_UUID already exists"
    return 0
  fi
  if [[ ! -e "$create" ]]; then
    fail "$create not found — check IGPU_BDF / MDEV_TYPE in config.env, and run './setup.sh check'"
    exit 1
  fi
  echo "$MDEV_UUID" | sudo tee "$create" >/dev/null
  ok "created mdev $MDEV_UUID (type $MDEV_TYPE)"
}

cmd_boot_service() {
  require_mdev_vars
  local unit=/etc/systemd/system/setup-gvt.service
  sudo tee "$unit" >/dev/null <<EOF
[Unit]
Description=Create GVT-g mdev instance ($MDEV_UUID)
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo $MDEV_UUID > /sys/bus/mdev_bus/$IGPU_BDF/mdev_supported_types/$MDEV_TYPE/create'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now setup-gvt.service
  ok "installed + enabled $unit"
}

cmd_udev() {
  sudo tee /etc/udev/rules.d/99-vfio-kvm.rules >/dev/null <<'EOF'
SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm", MODE="0660"
EOF
  sudo udevadm control --reload
  sudo udevadm trigger
  ok "installed /etc/udev/rules.d/99-vfio-kvm.rules (make sure your user is in the kvm group)"
}

cmd_snippet() {
  require_mdev_vars
  local out="$SCRIPT_DIR/domain-gvt-snippet.xml"
  cat > "$out" <<EOF
<!-- Merge into your libvirt domain XML (see README §5/§6/§9). -->

<!-- 1) vGPU passthrough: put inside <qemu:commandline>.
     On QEMU >= 10/11 do NOT add x-igd-opregion=on / romfile=... (firmware spin). -->
<qemu:commandline>
  <qemu:arg value='-device'/>
  <qemu:arg value='vfio-pci,sysfsdev=/sys/bus/mdev/devices/$MDEV_UUID,addr=$VGPU_ADDR,display=off'/>
</qemu:commandline>

<!-- 2) Networking that works in macOS: vmxnet3 on the PCI ROOT BUS (bus 0),
     rom bar off, slirp NAT. Behind a PCIe root-port the driver will not load. -->
<interface type='user'>
  <mac address='$GUEST_MAC'/>
  <model type='vmxnet3'/>
  <rom bar='off'/>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
</interface>
EOF
  ok "wrote $out"
}

cmd_inject() {
  local devid="${1:-}" platid="${2:-}"
  local oc="$OSX_KVM_DIR/OpenCore/OpenCore.qcow2"
  if [[ ! -f "$oc" ]]; then
    fail "$oc not found — set OSX_KVM_DIR in config.env"
    exit 1
  fi
  if virsh -c qemu:///system list --name 2>/dev/null | grep -qx "$VM_DOMAIN"; then
    fail "$VM_DOMAIN is running — shut it down first (guestfish needs the image unlocked)"
    exit 1
  fi
  mkdir -p "$SCRATCH_DIR"
  docker run --rm --network=host --user root --device /dev/kvm \
    -v "$OSX_KVM_DIR":/osxkvm -v "$SCRATCH_DIR":/scratch -v "$SCRATCH_DIR"/guestfs-cache:/var/tmp \
    --entrypoint sh "$DOCKER_IMAGE" -c 'guestfish --rw -a /osxkvm/OpenCore/OpenCore.qcow2 <<EOF
run
mount /dev/sda1 /
download /EFI/OC/config.plist /scratch/oc-orig.plist
EOF'
  python3 "$SCRIPT_DIR/patch_plist.py" "$SCRATCH_DIR/oc-orig.plist" "$SCRATCH_DIR/oc-injected.plist" $devid $platid
  docker run --rm --network=host --user root --device /dev/kvm \
    -v "$OSX_KVM_DIR":/osxkvm -v "$SCRATCH_DIR":/scratch -v "$SCRATCH_DIR"/guestfs-cache:/var/tmp \
    --entrypoint sh "$DOCKER_IMAGE" -c 'guestfish --rw -a /osxkvm/OpenCore/OpenCore.qcow2 <<EOF
run
mount /dev/sda1 /
upload /scratch/oc-injected.plist /EFI/OC/config.plist
EOF'
  ok "injected DeviceProperties into $oc (original plist saved at $SCRATCH_DIR/oc-orig.plist)"
}

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-help}" in
  check)        cmd_check ;;
  mdev)         cmd_mdev ;;
  boot-service) cmd_boot_service ;;
  udev)         cmd_udev ;;
  snippet)      cmd_snippet ;;
  inject)       shift; cmd_inject "$@" ;;
  all)
    cmd_check
    cmd_mdev
    cmd_boot_service
    cmd_udev
    cmd_snippet
    echo
    echo "Next steps:"
    echo "  1) ./setup.sh inject          # patch OpenCore (VM must be off)"
    echo "  2) merge domain-gvt-snippet.xml into your libvirt domain (README §5/§6/§9)"
    ;;
  *) usage; exit 1 ;;
esac
