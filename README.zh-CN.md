# 在 macOS 虚拟机中直通 Intel 核显(GVT-g)

<p align="right">
  <a href="./README.md"><img src="https://img.shields.io/badge/English-README-lightgrey" alt="English"/></a>
  <img src="https://img.shields.io/badge/%E4%B8%AD%E6%96%87-README-blue" alt="中文"/>
</p>

> **本项目基于 [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM)**;
> Docker 方案部分还借鉴了 [sickcodes/Docker-OSX](https://github.com/sickcodes/Docker-OSX)。
> 在 QEMU 下运行 macOS 的所有功劳归上游项目。

这是一份可复现的分步教程:把 **Intel 核芯显卡**通过 **GVT-g(mdev 半直通)**
传给 QEMU/libvirt 里的 macOS 虚拟机,并给出在新版(QEMU >= 9 / 11)环境下
**显示分辨率**与**联网**的可用方案。

> **免责声明**:在非苹果硬件上运行 macOS 可能违反 Apple EULA。
> 本资料仅供学习交流,风险自负。

---

## 0. 结论速览:什么能用、什么不能

| 项目 | 状态 |
|---|---|
| GVT-g vGPU 直通(macOS 可枚举到 Intel GPU) | 可用 |
| vGPU 输出 UEFI/OpenCore 启动画面 | 可用(QEMU 9 + i915ovmf ROM,见 §6) |
| 图形加速(QE/CI) | **不可用** —— 上游已知限制 |
| 启动时指定分辨率(实测最高 2560x1600) | 可用 |
| 联网(vmxnet3 + slirp NAT) | 可用 |

加速不可用的原因:Apple 帧缓冲驱动无法在"中介化(虚拟)GPU"上完成注册。
上游跟踪:[acidanthera/bugtracker#1914](https://github.com/acidanthera/bugtracker/issues/1914)(仍 open);
[patmagauran/i915ovmfPkg](https://github.com/patmagauran/i915ovmfPkg) 已于 2023-11 归档。
macOS 会回落到 vmware-svga 显示,日常使用不受影响。

---

## 1. 占位符约定

教程中的占位符请替换为你自己的值:

| 占位符 | 含义 | 示例 |
|---|---|---|
| `<YOUR_USER>` | 你的 Linux 用户名 | `alice` |
| `$HOME/OSX-KVM` | kholia/OSX-KVM 的本地目录 | `/home/alice/OSX-KVM` |
| `<IGPU_PCI_ID>` | 核显 PCI vendor:device id | `8086:5917`(UHD 620) |
| `<IGPU_BDF>` | 核显 PCI 总线地址 | `0000:00:02.0` |
| `<MDEV_UUID>` | 你为 GVT-g mdev 实例选定的 UUID | `uuidgen` 生成即可 |
| `<VFIO_GROUP>` | mdev 分配到的 VFIO group 号 | `18`(即 `/dev/vfio/18`) |
| `<MAC_ADDRESS>` | 客户机网卡 MAC | `52:54:00:xx:xx:xx` |
| `<MDEV_TYPE>` | 选择的 GVT-g 类型 | `i915-GVTg_V5_8` |

### 1.1 脚本参数化:一切来自 `config.env`

辅助脚本中**不再硬编码**任何路径、UUID、镜像名或端口,启动时统一读取本地
`config.env`:

```sh
cp config.env.example config.env   # 然后填入你自己的值
```

- `config.env.example`(提交到仓库):列出所有变量及安全默认值。
- `config.env`(你本地的):存放个人值,已列入 `.gitignore`,**永远不会被提交**;
  请勿把 UUID/敏感信息写进任何被跟踪的文件。
- 各脚本参数化前的原版已备份为 `*.bak`,同样被 gitignore。

---

## 2. 前提条件

**硬件**

- 支持 GVT-g 的 Intel 核显(大致为第 6 代 Skylake 至第 10 代;本教程在 UHD 620 上开发)。
- BIOS 开启 VT-d。
- 核显继续由宿主显示栈使用(笔记本友好方案,**不** unbind 核显)。

**软件**

- 内核含 `CONFIG_DRM_I915_GVT_KVMGT`(多数发行版内核默认带)。
- QEMU >= 9(本教程在 QEMU 11 上开发验证,差异处有说明)。
- libvirt + virt-manager(可选,推荐)。
- libguestfs(`guestfish`),用于修改 OpenCore 盘镜像。
- Docker(仅当需要 §11 的 Docker 方案)。

---

## 3. 宿主一次性准备

### 3.1 内核命令行

```
intel_iommu=on iommu=pt i915.enable_gvt=1
```

`i915.enable_fbc=0` 可选。修改引导器配置后重启。

### 3.2 KVM 忽略未处理 MSR(macOS 必需)

```sh
echo 1 | sudo tee /proc/sys/kernel/ignore_msrs
# 持久化:写入 /etc/rc.local 或 tmpfiles,如 kernel.ignore_msrs = 1
```

### 3.3 创建 GVT-g mdev

查看支持的类型:

```sh
ls /sys/class/mdev_bus/<IGPU_BDF>/mdev_supported_types/
# 如 i915-GVTg_V5_1 / V5_2 / V5_4 / V5_8(V5_8 为最大份额,本教程所用)
```

创建实例(需加载 `kvmgt` 模块,通常自动):

```sh
sudo modprobe kvmgt
echo '<MDEV_UUID>' | sudo tee /sys/class/mdev_bus/<IGPU_BDF>/mdev_supported_types/<MDEV_TYPE>/create
```

验证:

```sh
ls /sys/bus/mdev/devices/   # 应出现 <MDEV_UUID>
ls -l /dev/vfio/            # 记下 group 号 -> <VFIO_GROUP>
```

开机自动创建可用 systemd 单元:

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

### 3.4 VFIO 设备权限

```
# /etc/udev/rules.d/vfio-kvm.rules
SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm", MODE="0660"
```

然后 `sudo udevadm control --reload && sudo udevadm trigger`,并确保用户在 `kvm` 组。

---

## 4. 基础 macOS 虚拟机(来自 OSX-KVM)

按上游 [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) 拉取恢复镜像并安装 macOS。
完成后应有:

- `$HOME/OSX-KVM/mac_hdd_ng.img` —— 已安装的 macOS 磁盘(本教程用 Ventura 13.6)
- `$HOME/OSX-KVM/OpenCore/OpenCore.qcow2` —— OpenCore 启动盘
- `$HOME/OSX-KVM/OVMF_CODE.fd` —— UEFI 固件

将 VM 导入 libvirt(或从 OSX-KVM 的 `macOS.xml` 出发)。
新版 QEMU 下老模板需要 §5 的修复。

> **提示**:给 libvirt 单独一份 NVRAM 副本(如 `OVMF_VARS-libvirt.fd`)。
> `virsh undefine --nvram`(及 virt-manager 删除 VM 时的"删除 NVRAM"选项)
> 会删除 `<nvram>` 指向的文件,用独立副本可避免误删原始文件。

---

## 5. 适配新版 QEMU(>= 9)的 libvirt 域配置

OSX-KVM 老模板面向旧版 QEMU,必须修改:

| 原配置 | 新版 QEMU 的问题 | 修复 |
|---|---|---|
| `machine='pc-q35-4.2'` | 旧 machine type 已移除(`does not support machine type`) | `pc-q35-9.2`(用 `qemu-system-x86_64 -machine help` 查) |
| `graphics type='spice'` | QEMU 已移除 SPICE | `type='vnc'` |
| `video model='virtio'` | macOS 无 virtio-gpu 驱动,黑屏 | `vmvga`(VMware SVGA) |
| `vmvga` 被放到 PCIe root-port 后 | OVMF 报 `Missing compatible GOP`、"guest has not initialized the display" | 显式 `<address type='pci' bus='0x00' slot='0x02'/>`(PCI 根总线) |
| ich9-ehci + 3×uhci | 老旧 | 单个 `qemu-xhci`;输入设备用 `<input type='tablet' bus='usb'/>`,勿用 `qemu:arg -device usb-tablet`(总线顺序报 `No 'usb-bus'`) |
| BaseSystem 安装盘 | libvirt 不支持 readonly SATA 盘 | 移除(装完系统不再需要) |

### 5.1 以本人身份运行 QEMU(system 模式)

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

然后 `sudo systemctl restart libvirtd`。

说明:

- `cgroup_device_acl` 是 **cgroup 设备白名单**——缺两个 vfio 条目时,即使文件权限正确,
  QEMU 也会报 `Could not open '/dev/vfio/<VFIO_GROUP>': Operation not permitted`。
- 备选:用 `qemu:///session`(QEMU 以你的身份运行,无需 root),
  代价是无 autostart、网络需自理。

---

## 6. 把 GVT-g 传进虚拟机

在域 XML 中加入(根元素需 `xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0"`):

```xml
<qemu:commandline>
  <qemu:arg value='-device'/>
  <qemu:arg value='vfio-pci,sysfsdev=/sys/bus/mdev/devices/<MDEV_UUID>,addr=06.0,display=off'/>
</qemu:commandline>
```

要点:

- `sysfsdev=...` 是 mdev 的标准挂法(不是 `host=`)。
- `addr=06.0` 使 vGPU 位于 ACPI 路径 `PciRoot(0x0)/Pci(0x6,0x0)`——§7 注入时要用到。
  选空闲槽位,必要时用 monitor `info pci` 探测。
- **QEMU >= 10/11**:**不要**加 `x-igd-opregion=on` 或 `romfile=i915ovmf.rom`,
  否则 OVMF/OpenCore 死循环(单核 100%、黑屏、串口无声)。
  纯 `vfio-pci` 设备即可:macOS 能枚举到 GPU
  (系统信息显示 `Intel HD Graphics (GVT-g)`、Built-In、"No Kext Loaded")。
- **QEMU 9**(如 Docker-OSX 容器内):完整组合
  `display=on,x-igd-opregion=on,romfile=i915ovmf.rom` 可用,vGPU 能输出 UEFI 启动画面
  (需 `-display gtk,gl=on` 与 `/dev/dri` 设备)。
  [i915ovmf.rom](https://github.com/patmagauran/i915ovmfPkg) 需自行编译。

---

## 7. OpenCore 配置(注入 + 串口 + 分辨率)

编辑 `OpenCore.qcow2` 内的 `/EFI/OC/config.plist`(GPT,EFI 分区为 `/dev/sda1`,FAT):

```sh
guestfish --rw -a OpenCore.qcow2 -m /dev/sda1:/ \
  download /EFI/OC/config.plist /tmp/config.plist
# 编辑 /tmp/config.plist 后:
guestfish --rw -a OpenCore.qcow2 -m /dev/sda1:/ \
  upload /tmp/config.plist /EFI/OC/config.plist
```

(VM 必须**关机**——运行时 QEMU 持有镜像写锁。)

### 7.1 核显 DeviceProperties 注入

对应 `PciRoot(0x0)/Pci(0x6,0x0)` 的 vGPU(UHD 620 示例;base64 为**小端**字节):

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

(早期社区成功案例用 Skylake 欺骗变体:`device-id`/`ig-platform-id` 均为 `FhkAAA==`(0x1916)。)

### 7.2 boot-args 与其他键

- boot-args 必须放 `NVRAM -> Add -> 7C436110-AB2A-4BBB-A880-FE41995C9F82 -> boot-args`
  (放 `Misc.Boot` 会报 `OCS: No schema for Boot-args`)。
- 建议 boot-args:`-v keepsyms=1 serial=3`(详细日志 + 内核串口)。
- `UEFI -> Output`:`Resolution` = `Max`(或 `<WxH>`),`ProvideConsoleGop = True`。

### 7.3 验证

串口出现以下日志即直通链路成立:

```
[IGPU] Graphics driver failed to load: could not register with Framebuffer driver!
```

含义:Apple 驱动**已绑定**注入的设备并尝试初始化——VFIO/mdev/注入全部工作,
仅帧缓冲注册失败(即 §0 的已知限制)。

---

## 8. 显示分辨率

此处 macOS 走 EFI 帧缓冲(vmare-svga 无 macOS 原生驱动),
**系统设置内无法热切换分辨率**。只能在启动时指定:

- OpenCore `UEFI -> Output -> Resolution` = `<WxH>` 或 `Max`(按 §7 方法修改),重启生效。
- 实测:`1920x1200` 与 `Max` = `2560x1600`。

仓库附带的 `set-res.sh` 可自动完成 guestfish 修改。

---

## 9. 联网(最大的坑)

**症状**:VM 正常启动,但 macOS 浏览器报 "You Are Not Connected to the Internet";
`ifconfig` 里根本没有 `en0`。

### 9.1 排查矩阵(QEMU 11,全部实测)

| 网卡 model | 后端 / PCI 位置 | 结果 |
|---|---|---|
| `virtio` | default(tap/virbr0) | macOS **无 virtio-net 驱动**,系统内根本没有网卡 |
| `vmxnet3` | default(tap/virbr0) | OVMF/OpenCore **固件空转**(单核 100%、黑屏) |
| `vmxnet3` | user + 自动 PCIe root-port | 能引导,但**驱动不加载、无 en0** |
| `vmxnet3` | user + **PCI 根总线(bus 0)** | **en0 正常 attach,联网成功**(最终方案) |
| `e1000-82545em` | user + 根总线 | 固件空转(且 macOS 亦无 e1000 驱动) |

### 9.2 最终可用配置

```xml
<interface type='user'>
  <mac address='<MAC_ADDRESS>'/>
  <model type='vmxnet3'/>
  <rom bar='off'/>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
</interface>
```

原因:

- **网卡必须在 PCI 根总线(bus 0)**。放在 PCIe root-port 后面时,macOS 不把它当内置网卡,
  vmxnet3 驱动不加载(无 `en0`)。这是"无法联网"的真正根因。
- `vmxnet3` 有 macOS 原生驱动;`virtio`/`e1000` 均无。
- `rom bar='off'` 禁止 OVMF 执行网卡 EFI option ROM,规避固件空转。
- `type='user'`(slirp)自带 NAT:客户机 `10.0.2.15`,网关/DNS `10.0.2.x`,
  宿主可通过 `10.0.2.2` 访问。

验证:串口出现 `ifnet_attach: ... interface en0` 即驱动加载成功。

### 9.3 诊断命令

- `virsh net-dhcp-leases default` —— 桥接模式查租约
- QEMU monitor:`info usernet`(slirp 连接)、`info qtree`(网卡属性)、`screendump`
- 串口日志(`serial=3`):grep `en0|IGPU|IONetwork|8254`
- `ps -eo pcpu` 单核 ~100% = 固件空转特征

---

## 10. 调试工具箱

- **截屏**:加 `-monitor unix:/tmp/qemu-mon.sock,server,nowait`,
  然后 `echo screendump ... | socat - UNIX-CONNECT:/tmp/qemu-mon.sock`(见 `mon.sh`)。
- **内核串口日志**:`-serial tcp:0.0.0.0:4444,server,nowait` + boot-args `serial=3`,
  宿主 `nc localhost 4444` 抓取。(Ventura 单用户 `-s` shell 不走串口,仅作日志用。)
- **PCI 拓扑**:monitor `info pci`。
- **guestfish 写锁**:VM 运行时不要改 `OpenCore.qcow2`,在副本上操作。
- libguestfs 不支持 APFS;检查安装镜像请用 `7z` 从 `BaseSystem.dmg` 提取。

---

## 11. 备选方案:Docker-OSX 版

同样的直通也可在 [sickcodes/Docker-OSX](https://github.com/sickcodes/Docker-OSX) 内完成
(容器自带 QEMU 9,i915ovmf ROM 组合可用):

```
-device vfio-pci,sysfsdev=/sys/bus/mdev/devices/<MDEV_UUID>,addr=06.0,display=on,x-igd-opregion=on,romfile=/path/to/i915ovmf.rom
```

所有参数经 `-e EXTRA="..."` 注入(Docker-OSX 启动命令末尾是 `${EXTRA}`)。

容器特有的坑:

- 部分宿主上 docker bridge 网络失败(`veth pair: operation not supported`)→ 用 `--network host`。
- GUI 显示:挂 `/tmp/.X11-unix`,提供 Xauthority,设 `DISPLAY`。
- `vfio-display-dmabuf: opengl not available` → `-display gtk,gl=on`。
- `egl: failed to create dri2 screen` → 传 `--device /dev/dri/card0 --device /dev/dri/renderD128`。
- `/dev/vfio/<VFIO_GROUP>` 权限 → 容器以 root 运行(Docker-OSX 内部本来就用 sudo)。

---

## 12. 已知限制与可继续尝试的方向

- 无 QE/CI 加速(§0)。可尝试:其他 platform-id(`0x00005912`、`0x0000591B`、
  Skylake `0x1916` 系)、更小的 mdev 类型(`V5_4`)、更老的 macOS
  (Catalina 有社区成功报告)、或仅把 vGPU 当显示头(`-igfxvesa`)。

---

## 13. 参考链接

| 链接 | 内容 |
|---|---|
| https://github.com/kholia/OSX-KVM | 本教程所基于的基础项目 |
| https://github.com/sickcodes/Docker-OSX | Docker 方案所用的容器项目 |
| https://github.com/patmagauran/i915ovmfPkg | i915ovmf UEFI ROM(已归档 2023-11) |
| https://github.com/patmagauran/i915ovmfPkg/wiki/GVT-G-vs-GVT-D | GVT-g 与 GVT-d 的区别 |
| https://wiki.archlinux.org/index.php/Intel_GVT-g | ArchWiki:Intel GVT-g 配置 |
| https://github.com/acidanthera/bugtracker/issues/1914 | macOS + GVT-g 帧缓冲失败的权威跟踪 |
| https://github.com/acidanthera/WhateverGreen(FAQ.IntelHD) | Intel 帧缓冲 device-id/platform-id 参考 |
| https://github.com/sickcodes/Docker-OSX/issues/133 | Docker-OSX 核显直通讨论 |
| https://github.com/vivekmiyani/OSX_GVT-D | GVT-d + macOS 参考仓库 |

---

## 14. 仓库文件清单

| 文件 | 用途 |
|---|---|
| `config.env.example` | 本地配置模板(复制为 `config.env` 使用) |
| `boot.sh` | Docker-OSX 变体:一键启动并带 GVT-g 直通(§11) |
| `set-res.sh <WxH\|Max>` | 修改 OpenCore 启动分辨率(需先关 VM,§8) |
| `mon.sh "<monitor 命令>"` | 向 QEMU monitor 发命令,如 `"info pci"`、`"screendump x"` |
| `iterate.sh <devid> <platid> <tag>` | 改 plist → 换盘 → 重启 → 抓串口(device-id 批量试验) |
| `patch_plist.py <in> <out> [devid] [platid]` | 生成注入后的 OpenCore `config.plist`(§7) |
| `su-interact.sh` | 串口交互调试助手(§10) |

`OpenCore.qcow2` / `OVMF_VARS.fd` 仅为本地样本(已 gitignore:大体积二进制、可能含
主机相关信息)。请按 §7 的 plist 片段自行生成 OpenCore 配置。

---

## 附录:参考宿主配置

本教程开发与验证所用的机器:

| 项目 | 值 |
|---|---|
| 笔记本 | Dell XPS 13,Intel i7-8550U(Kaby Lake-R) |
| 核显 | UHD Graphics 620,`<IGPU_PCI_ID>` = `8086:5917`(rev 07) |
| 宿主系统 | Void Linux,kernel 7.1 x86_64,Wayland(mutter/XWayland) |
| 内核参数 | `intel_iommu=on iommu=pt i915.enable_gvt=1 i915.enable_fbc=0` |
| kvm | `ignore_msrs = Y` |
| QEMU / libvirt | QEMU 11.0.3(宿主)/ 9.0.0(容器);libvirt 12.6.0 |
| macOS 客户机 | Ventura 13.6(build 22G120),qcow2 磁盘 |
| mdev 类型 | `i915-GVTg_V5_8` |
| 最高分辨率 | 2560x1600(`Resolution=Max`) |

其他核显代际效果可能不同——新版内核/核显已移除 GVT-g 支持,
请先检查 `mdev_supported_types`。
