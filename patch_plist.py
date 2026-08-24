#!/usr/bin/env python3
# 用法: ./patch_plist.py <原始config.plist> <输出config.plist> [devid-hex] [platform-id-hex]
# 为 GVT-g vGPU 注入 DeviceProperties, 默认 Kaby Lake HD 620 组合
import plistlib, sys

src, dst = sys.argv[1], sys.argv[2]
devid = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x5916
platid = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0x00005916

with open(src, 'rb') as f:
    p = plistlib.load(f)

def b32(v):
    return v.to_bytes(4, 'little')

# vGPU 在 docker-osx q35 布局中位于 00:06.0 (00:02.0 被 qemu-xhci 占用)
p['DeviceProperties']['Add']['PciRoot(0x0)/Pci(0x6,0x0)'] = {
    'device-id': b32(devid),
    'AAPL,ig-platform-id': b32(platid),
    'framebuffer-patch-enable': b32(1),
    'framebuffer-stolenmem': b32(0x01300000),
    'framebuffer-fbmem': b32(0x00900000),
    'model': 'Intel HD Graphics (GVT-g)',
}

# 注意: boot-args 只能放在 NVRAM 下, Misc.Boot 没有 Boot-args 这个 schema
p['Misc']['Boot'].pop('Boot-args', None)
guid = '7C436110-AB2A-4BBB-A880-FE41995C9F82'
args = p['NVRAM']['Add'][guid].get('boot-args', '')
if len(sys.argv) > 5:
    p['NVRAM']['Add'][guid]['boot-args'] = sys.argv[5]
elif 'serial=3' not in args:
    p['NVRAM']['Add'][guid]['boot-args'] = args

with open(dst, 'wb') as f:
    plistlib.dump(p, f)
print('wrote', dst, 'devid=%04x platid=%08x' % (devid, platid))
