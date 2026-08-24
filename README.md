# macOS VM with Intel iGPU (GVT-g) Passthrough

<p align="right">
  <img src="https://img.shields.io/badge/English-README-blue" alt="English"/>
  <a href="./README.zh-CN.md"><img src="https://img.shields.io/badge/%E4%B8%AD%E6%96%87-README-lightgrey" alt="中文"/></a>
</p>

> **This project is based on [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM).**
> Parts of the Docker-based variant also build on [sickcodes/Docker-OSX](https://github.com/sickcodes/Docker-OSX).
> All credits for running macOS under QEMU belong to those upstream projects.

This is a step-by-step, reproducible tutorial for passing an **Intel integrated GPU**
(via **GVT-g / mediated passthrough**) into a macOS VM running on QEMU/libvirt,
plus working solutions for **display resolution** and **networking** on a modern
(QEMU >= 9 / 11) stack.

> **Disclaimer**: Running macOS on non-Apple hardware may violate Apple's EULA.
> This material is published for educational purposes only. Use at your own risk.

---

## 0. What works / what does not

| Item | Status |
|---|---|
| GVT-g vGPU passthrough (device enumerated by macOS) | Works |
| UEFI/OpenCore boot display via vGPU | Works (QEMU 9 + i915ovmf ROM; see §6) |
| Graphics acceleration (QE/CI) | **Not working** — known upstream limitation |
| Boot-time display resolution control (tested up to 2560x1600) | Works |
| Networking (vmxnet3 + slirp NAT) | Works |

The acceleration limitation: Apple's framebuffer driver cannot register on a mediated
(virtual) GPU. Tracked upstream at
[acidanthera/bugtracker#1914](https://github.com/acidanthera/bugtracker/issues/1914)
(still open); [patmagauran/i915ovmfPkg](https://github.com/patmagauran/i915ovmfPkg)
was archived in 2023-11. macOS falls back to vmware-svga display, which is fully usable.

---

## 1. Placeholder conventions used in this tutorial

Replace these with your own values:

| Placeholder | Meaning | Example |
|---|---|---|
| `<YOUR_USER>` | your Linux login user | `alice` |
| `$HOME/OSX-KVM` | your checkout of kholia/OSX-KVM | `/home/alice/OSX-KVM` |
| `<IGPU_PCI_ID>` | PCI vendor:device id of the iGPU | `8086:5917` (UHD 620) |
| `<IGPU_BDF>` | PCI bus address of the iGPU | `0000:00:02.0` |
| `<MDEV_UUID>` | UUID you choose for the GVT-g mdev instance | any UUID, e.g. from `uuidgen` |
| `<VFIO_GROUP>` | VFIO group number assigned to the mdev | `18` (`/dev/vfio/18`) |
| `<MAC_ADDRESS>` | MAC address of the guest NIC | `52:54:00:xx:xx:xx` |
| `<MDEV_TYPE>` | GVT-g type you pick | `i915-GVTg_V5_8` |

### 1.1 Scripts read everything from `config.env`

No path, UUID, image name or port is hard-coded in the helper scripts. They all load a
single local file `config.env` at startup:

```sh
cp config.env.example config.env   # then edit with your own values
```

- `config.env.example` (committed) documents every variable with safe defaults.
- `config.env` (yours) holds personal values — it is listed in `.gitignore`, so it is
  **never committed**. Do not put secrets/UUIDs into any tracked file.
- Originals of every script were saved as `*.bak` before parameterization; `*.bak` is
  also gitignored.

---

## 2. Requirements

**Hardware**

- Intel CPU with a GVT-g capable iGPU (roughly Gen 6 "Skylake" through Gen 10; this tutorial was developed on UHD 620).
- VT-d enabled in BIOS.
- The iGPU must stay bound to the host display stack (this is a laptop-friendly setup; we do *not* unbind the iGPU).

**Software**

- Linux kernel with `CONFIG_DRM_I915_GVT_KVMGT` (most distro kernels have it).
- QEMU >= 9 (developed and tested on QEMU 11; differences noted where relevant).
- libvirt + virt-manager (optional but recommended).
- libguestfs (`guestfish`) for editing the OpenCore disk image.
- Docker (only if you want the Docker-OSX variant, §11).

---

## 3. Host preparation (one-time)

### 3.1 Kernel command line

```
intel_iommu=on iommu=pt i915.enable_gvt=1
```

`i915.enable_fbc=0` is optional. Reboot after editing your bootloader config.

### 3.2 KVM: ignore unhandled MSRs (required by macOS)

```sh
echo 1 | sudo tee /proc/sys/kernel/ignore_msrs
# make persistent, e.g. /etc/rc.local or a tmpfiles entry:
# kernel.ignore_msrs = 1
```

### 3.3 Create the GVT-g mdev

Check supported types:

```sh
ls /sys/class/mdev_bus/<IGPU_BDF>/mdev_supported_types/
# e.g. i915-GVTg_V5_1 / V5_2 / V5_4 / V5_8 (V5_8 = largest share used here)
```

Create an instance (needs the `kvmgt` module loaded, usually automatic):

```sh
sudo modprobe kvmgt
echo '<MDEV_UUID>' | sudo tee /sys/class/mdev_bus/<IGPU_BDF>/mdev_supported_types/<MDEV_TYPE>/create
```

Verify:

```sh
ls /sys/bus/mdev/devices/            # shows <MDEV_UUID>
ls -l /dev/vfio/                     # note the group number -> <VFIO_GROUP>
```

To make it survive reboots, use a systemd unit:

```ini
# /etc/systemd/system/setup-gvt.service
[Unit]
Description=Create GVT-g mdev instance
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo <MDEV_UUID> > /sys/class/mdev_bus/<IGPU_BDF>/mdev_supported_types/<MDEV_TYPE>/create'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
```

### 3.4 Permissions for VFIO devices

```
# /etc/udev/rules.d/vfio-kvm.rules
SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm", MODE="0660"
```

Then `sudo udevadm control --reload && sudo udevadm trigger`.
Make sure your user is in the `kvm` group.

---

## 4. Base macOS VM (from OSX-KVM)

Follow upstream [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) to fetch the
recovery image and install macOS. After this step you should have:

- `$HOME/OSX-KVM/mac_hdd_ng.img` — installed macOS disk (this tutorial used Ventura 13.6)
- `$HOME/OSX-KVM/OpenCore/OpenCore.qcow2` — OpenCore boot disk
- `$HOME/OSX-KVM/OVMF_CODE.fd` — UEFI firmware

Import the VM into libvirt (or start from OSX-KVM's `macOS.xml`).
On a modern QEMU the stock template needs the fixes in §5.

> **Tip**: keep a dedicated NVRAM copy for libvirt (e.g. `OVMF_VARS-libvirt.fd`).
> `virsh undefine --nvram` (and virt-manager's "delete NVRAM" checkbox) deletes the
> file pointed to by `<nvram>` — use an isolated copy so you never destroy the original.

---

## 5. Fixing the libvirt domain for modern QEMU (>= 9)

The classic OSX-KVM template targets old QEMU. Required changes:

| Old config | Problem on QEMU >= 9 | Fix |
|---|---|---|
| `machine='pc-q35-4.2'` | old machine types removed (`does not support machine type`) | `pc-q35-9.2` (check `qemu-system-x86_64 -machine help`) |
| `graphics type='spice'` | SPICE removed from QEMU | `type='vnc'` |
| `video model='virtio'` | no virtio-gpu driver in macOS, black screen | `vmvga` (VMware SVGA) |
| `vmvga` placed behind a PCIe root-port | OVMF: `Missing compatible GOP`; "guest has not initialized the display" | explicit `<address type='pci' bus='0x00' slot='0x02'/>` (root bus) |
| ich9-ehci + 3x uhci | legacy | single `qemu-xhci`; use `<input type='tablet' bus='usb'/>` instead of `qemu:arg -device usb-tablet` (bus-ordering error `No 'usb-bus'`) |
| installer BaseSystem disk | readonly SATA disks unsupported by libvirt | remove it (not needed after install) |

### 5.1 Run QEMU as your own user (system mode)

`/etc/libvirt/qemu.conf`:

```
user = "<YOUR_USER>"
group = "<YOUR_USER>"
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm",
    "/dev/vfio/vfio", "/dev/vfio/<VFIO_GROUP>"
]
```

Then `sudo systemctl restart libvirtd`.

Notes:

- `cgroup_device_acl` is a **cgroup device whitelist** — without the two vfio entries,
  QEMU fails with `Could not open '/dev/vfio/<VFIO_GROUP>': Operation not permitted`
  even when file permissions are correct.
- Alternative: use `qemu:///session` (QEMU runs as you, no root needed), at the cost of
  no autostart and manual networking.

---

## 6. GVT-g passthrough into the VM

Add to the domain XML (inside `<domain ... xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">`):

```xml
<qemu:commandline>
  <qemu:arg value='-device'/>
  <qemu:arg value='vfio-pci,sysfsdev=/sys/bus/mdev/devices/<MDEV_UUID>,addr=06.0,display=off'/>
</qemu:commandline>
```

Key points:

- `sysfsdev=...` is the standard way to attach an mdev (not `host=`).
- `addr=06.0` puts the vGPU at ACPI path `PciRoot(0x0)/Pci(0x6,0x0)` — remember it for
  the OpenCore injection in §7. Pick a free slot (probe with monitor `info pci` if needed).
- **QEMU >= 10/11**: do **not** add `x-igd-opregion=on` or `romfile=i915ovmf.rom` —
  they make OVMF/OpenCore spin forever (one CPU core at 100%, black screen, silent serial).
  The plain `vfio-pci` device is enough: macOS enumerates the GPU
  (System Information shows `Intel HD Graphics (GVT-g)`, Built-In, "No Kext Loaded").
- **QEMU 9** (e.g. inside the Docker-OSX container): the full combo
  `display=on,x-igd-opregion=on,romfile=i915ovmf.rom` works and gives a UEFI boot
  display on the vGPU (needs `-display gtk,gl=on` and `/dev/dri` devices).
  [i915ovmf.rom](https://github.com/patmagauran/i915ovmfPkg) must be built yourself.

---

## 7. OpenCore configuration (injection + serial + resolution)

Edit `/EFI/OC/config.plist` inside `OpenCore.qcow2` (GPT; EFI partition is `/dev/sda1`, FAT):

```sh
guestfish --rw -a OpenCore.qcow2 -m /dev/sda1:/ \
  download /EFI/OC/config.plist /tmp/config.plist
# edit /tmp/config.plist, then:
guestfish --rw -a OpenCore.qcow2 -m /dev/sda1:/ \
  upload /tmp/config.plist /EFI/OC/config.plist
```

(The VM must be **off** — QEMU holds a write lock on the image while running.)

### 7.1 iGPU DeviceProperties injection

For the vGPU at `PciRoot(0x0)/Pci(0x6,0x0)` (UHD 620 example; base64 values are
**little-endian** bytes):

```xml
<key>PciRoot(0x0)/Pci(0x6,0x0)</key>
<dict>
  <key>device-id</key>               <data>FlkAAA==</data>  <!-- 0x5916 LE -->
  <key>AAPL,ig-platform-id</key>     <data>FlkAAA==</data>  <!-- 0x00005916 LE -->
  <key>framebuffer-patch-enable</key><data>AQAAAA==</data>
  <key>framebuffer-stolenmem</key>   <data>AAAwAQ==</data>  <!-- 0x01300000 -->
  <key>framebuffer-fbmem</key>       <data>AACQAA==</data>  <!-- 0x00900000 -->
  <key>model</key><string>Intel HD Graphics (GVT-g)</string>
</dict>
```

(A Skylake spoof variant — `device-id`/`ig-platform-id` both `FhkAAA==` (0x1916) — was
used in older community success reports.)

### 7.2 boot-args and other keys

- boot-args belong in `NVRAM -> Add -> 7C436110-AB2A-4BBB-A880-FE41995C9F82 -> boot-args`
  (NOT `Misc.Boot`, otherwise `OCS: No schema for Boot-args`).
- Useful boot-args: `-v keepsyms=1 serial=3` (verbose + kernel serial logging).
- `UEFI -> Output`: `Resolution` = `Max` (or `<WxH>`), `ProvideConsoleGop = True`.

### 7.3 Verification

Success marker on the serial console:

```
[IGPU] Graphics driver failed to load: could not register with Framebuffer driver!
```

This means the Apple driver **bound** to the injected device and tried to initialize it —
i.e. the whole passthrough chain (VFIO/mdev/injection) works; only the framebuffer
registration fails (the known limitation from §0).

---

## 8. Display resolution

macOS uses the EFI framebuffer here (vmware-svga has no native macOS driver), so
**resolution cannot be switched from inside macOS System Settings**. Set it at boot time:

- OpenCore `UEFI -> Output -> Resolution` = `<WxH>` or `Max` (edit as in §7), then reboot.
- Tested: `1920x1200` and `Max` = `2560x1600`.

A helper script (`set-res.sh`) automating the guestfish edit is included in this repo.

---

## 9. Networking (the tricky part)

**Symptom**: VM boots fine but macOS says "You Are Not Connected to the Internet";
`ifconfig` shows no `en0` at all.

### 9.1 Test matrix (QEMU 11, all combinations verified by hand)

| NIC model | Backend / PCI placement | Result |
|---|---|---|
| `virtio` | default (tap/virbr0) | **no virtio-net driver in macOS** — no NIC in the guest at all |
| `vmxnet3` | default (tap/virbr0) | OVMF/OpenCore **firmware spin** (100% single core, black screen) |
| `vmxnet3` | user + auto PCIe root-port | boots, but **driver not loaded, no en0** |
| `vmxnet3` | user + **PCI root bus (bus 0)** | **en0 attaches, networking works** (final solution) |
| `e1000-82545em` | user + root bus | firmware spin (and no e1000 driver in macOS anyway) |

### 9.2 Final working configuration

```xml
<interface type='user'>
  <mac address='<MAC_ADDRESS>'/>
  <model type='vmxnet3'/>
  <rom bar='off'/>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
</interface>
```

Why it works:

- **The NIC must sit on the PCI root bus (bus 0).** Behind a PCIe root-port, macOS does
  not treat it as built-in and the vmxnet3 driver never loads (no `en0`). This was the
  actual root cause of the "no internet" problem.
- `vmxnet3` has a native macOS driver; `virtio`/`e1000` do not.
- `rom bar='off'` stops OVMF from executing the NIC's EFI option ROM (avoids firmware spin).
- `type='user'` (slirp) gives NAT out of the box: guest `10.0.2.15`, gateway/DNS `10.0.2.x`,
  host reachable at `10.0.2.2`.

Verification: the serial log shows `ifnet_attach: ... interface en0` when the driver loads.

### 9.3 Diagnostic commands

- `virsh net-dhcp-leases default` — bridge mode lease check
- QEMU monitor: `info usernet` (slirp connections), `info qtree` (NIC link/props), `screendump`
- serial log (`serial=3`): grep for `en0|IGPU|IONetwork|8254`
- `ps -eo pcpu` showing one core pinned at ~100% = firmware spin signature

---

## 10. Debugging toolbox

- **Screenshots**: add `-monitor unix:/tmp/qemu-mon.sock,server,nowait`, then
  `echo screendump ... | socat - UNIX-CONNECT:/tmp/qemu-mon.sock` (see `mon.sh`).
- **Kernel serial log**: `-serial tcp:0.0.0.0:4444,server,nowait` + boot-args `serial=3`,
  connect with `nc localhost 4444`. (Ventura's single-user `-s` shell does not go over
  serial, so this is logging-only.)
- **PCI topology**: monitor `info pci`.
- **guestfish write lock**: never edit `OpenCore.qcow2` while the VM runs; work on a copy.
- libguestfs cannot read APFS; to inspect the installer, extract files from
  `BaseSystem.dmg` with `7z` instead.

---

## 11. Alternative: the Docker-OSX variant

The same passthrough also works inside [sickcodes/Docker-OSX](https://github.com/sickcodes/Docker-OSX)
(container ships QEMU 9, where the i915ovmf ROM combo still works):

```
-device vfio-pci,sysfsdev=/sys/bus/mdev/devices/<MDEV_UUID>,addr=06.0,display=on,x-igd-opregion=on,romfile=/path/to/i915ovmf.rom
```

Inject everything via `-e EXTRA="..."` (Docker-OSX appends `${EXTRA}` to the QEMU command).

Gotchas specific to the container:

- Docker bridge networking may fail on some hosts (`veth pair: operation not supported`) → use `--network host`.
- GUI display: mount `/tmp/.X11-unix`, provide an Xauthority, set `DISPLAY`.
- `vfio-display-dmabuf: opengl not available` → `-display gtk,gl=on`.
- `egl: failed to create dri2 screen` → pass `--device /dev/dri/card0 --device /dev/dri/renderD128`.
- `/dev/vfio/<VFIO_GROUP>` permission → run container as root (Docker-OSX uses sudo internally anyway).

---

## 12. Known limitations & further directions

- No QE/CI acceleration (§0). Things to try: other platform-ids (`0x00005912`, `0x0000591B`,
  Skylake `0x1916` family), smaller mdev type (`V5_4`), older macOS (Catalina has community
  success reports), or use the vGPU purely as a display head (`-igfxvesa`).

---

## 13. References

| Link | Content |
|---|---|
| https://github.com/kholia/OSX-KVM | base project this tutorial builds on |
| https://github.com/sickcodes/Docker-OSX | Docker-based macOS used for the container variant |
| https://github.com/patmagauran/i915ovmfPkg | i915ovmf UEFI ROM for GVT-g/d (archived 2023-11) |
| https://github.com/patmagauran/i915ovmfPkg/wiki/GVT-G-vs-GVT-D | GVT-g vs GVT-d explained |
| https://wiki.archlinux.org/index.php/Intel_GVT-g | ArchWiki: Intel GVT-g setup |
| https://github.com/acidanthera/bugtracker/issues/1914 | macOS + GVT-g framebuffer failure (authoritative tracker) |
| https://github.com/acidanthera/WhateverGreen (FAQ.IntelHD) | Intel framebuffer device-id / platform-id reference |
| https://github.com/sickcodes/Docker-OSX/issues/133 | Docker-OSX iGPU passthrough discussion |
| https://github.com/vivekmiyani/OSX_GVT-D | GVT-d + macOS reference repo |

---

## 14. Repository layout

| File | Purpose |
|---|---|
| `config.env.example` | template for local configuration (copy to `config.env`) |
| `boot.sh` | Docker-OSX variant: one-shot start with GVT-g passthrough (§11) |
| `set-res.sh <WxH\|Max>` | change boot resolution by editing OpenCore (VM must be off, §8) |
| `mon.sh "<monitor cmd>"` | send a command to the QEMU monitor, e.g. `"info pci"`, `"screendump x"` |
| `iterate.sh <devid> <platid> <tag>` | patch plist → swap disk → reboot → capture serial (device-id experiments) |
| `patch_plist.py <in> <out> [devid] [platid]` | generate an injected OpenCore `config.plist` (§7) |
| `su-interact.sh` | serial-console interaction helper for debugging (§10) |

`OpenCore.qcow2` / `OVMF_VARS.fd` are local-only samples (gitignored: large binaries,
host-specific data). Recreate the OpenCore config from the plist in §7 instead.

---

## Appendix: reference host configuration

The exact machine this tutorial was developed and verified on:

| Item | Value |
|---|---|
| Laptop | Dell XPS 13, Intel i7-8550U (Kaby Lake-R) |
| iGPU | UHD Graphics 620 `<IGPU_PCI_ID>` = `8086:5917` (rev 07) |
| Host OS | Void Linux, kernel 7.1 x86_64, Wayland (mutter/XWayland) |
| Kernel cmdline | `intel_iommu=on iommu=pt i915.enable_gvt=1 i915.enable_fbc=0` |
| kvm | `ignore_msrs = Y` |
| QEMU / libvirt | QEMU 11.0.3 (host) / 9.0.0 (container); libvirt 12.6.0 |
| macOS guest | Ventura 13.6 (build 22G120), qcow2 disk |
| mdev | type `i915-GVTg_V5_8` |
| Best resolution achieved | 2560x1600 (`Resolution=Max`) |

Your mileage may vary with other iGPU generations — GVT-g support was removed from
newer kernels/iGPUs, so check your `mdev_supported_types` first.
