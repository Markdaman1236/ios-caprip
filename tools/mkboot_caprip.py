#!/usr/bin/env python3
"""Pack a caprip (Motorola moto g30, SM6115 bengal) XNU boot image - stdlib only.

Geometry is caprip's own, read out of the live vendor_boot_a header:
  kernel @0x00008000, ramdisk @0x01000000, tags @0x00000100, dtb @0x01f00000,
  page 4096.

caprip ships boot header v3, where boot.img carries no DTB and no load
addresses -- ABL takes both from vendor_boot. Two ways to satisfy it:

  --header-version 2  (default)
      Self-contained: addresses and DTB live in the image, nothing else
      needed. `fastboot boot out/xnu-caprip.img`. Qualcomm ABL keeps a v0-v2
      parser, and this is the variant proven on gta4l (same SoC).

  --header-version 3
      Matches the stock layout, but ABL then needs the DTB from vendor_boot:
      `fastboot boot out/xnu-caprip.img out/vendor_boot-caprip.img`.

Both are RAM-only through `fastboot boot`; neither writes to the device.
"""
import argparse
import struct
import sys

PAGE = 4096
KERNEL_ADDR = 0x00008000
RAMDISK_ADDR = 0x01000000
TAGS_ADDR = 0x00000100
DTB_ADDR = 0x01F00000
HDR_V2_SIZE = 1660
HDR_V3_SIZE = 1580
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


def pad(data, page=PAGE):
    return data + b"\0" * (-len(data) % page)


def check_dtb(path):
    dtb = open(path, "rb").read()
    if dtb[:4] != FDT_MAGIC:
        sys.exit("%s: not a flattened device tree" % path)
    total = struct.unpack_from(">I", dtb, 4)[0]
    if total != len(dtb):
        sys.exit("%s: totalsize %d != file size %d (truncated?)" % (path, total, len(dtb)))
    for prop in (b"qcom,msm-id", b"qcom,board-id"):
        if prop not in dtb:
            sys.exit("%s: missing %s; ABL will reject it" % (path, prop.decode()))
    return dtb


def build_v2(kernel, ramdisk, dtb, cmdline, name):
    hdr = bytearray(HDR_V2_SIZE)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into(
        "<10I", hdr, 8,
        len(kernel), KERNEL_ADDR,
        len(ramdisk), RAMDISK_ADDR,
        0, 0,                       # second stage
        TAGS_ADDR, PAGE,
        2,                          # header_version
        0,                          # os_version
    )
    hdr[48:64] = name[:16].ljust(16, b"\0")
    hdr[64:576] = cmdline[:511].ljust(512, b"\0")
    struct.pack_into("<I", hdr, 1632, HDR_V2_SIZE)   # header_size
    struct.pack_into("<I", hdr, 1636, 0)             # recovery_dtbo_size
    struct.pack_into("<Q", hdr, 1640, 0)             # recovery_dtbo_offset
    struct.pack_into("<I", hdr, 1648, len(dtb))      # dtb_size
    struct.pack_into("<Q", hdr, 1652, DTB_ADDR)      # dtb_addr
    return pad(bytes(hdr)) + pad(kernel) + pad(ramdisk) + pad(dtb)


def build_v3(kernel, ramdisk, cmdline):
    hdr = bytearray(HDR_V3_SIZE)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<4I", hdr, 8, len(kernel), len(ramdisk), 0, HDR_V3_SIZE)
    struct.pack_into("<I", hdr, 40, 3)               # header_version
    hdr[44:44 + 1536] = cmdline[:1535].ljust(1536, b"\0")
    return pad(bytes(hdr)) + pad(kernel) + pad(ramdisk)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--dtb", help="board DTB (header v2 only)")
    ap.add_argument("--ramdisk")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--name", default="caprip-xnu")
    ap.add_argument("--header-version", type=int, default=2, choices=(2, 3))
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read() if a.ramdisk else b""
    cmdline = a.cmdline.encode()

    if a.header_version == 2:
        if not a.dtb:
            sys.exit("--dtb is required for header v2")
        dtb = check_dtb(a.dtb)
        img = build_v2(kernel, ramdisk, dtb, cmdline, a.name.encode())
        extra = "dtb %d @%#x" % (len(dtb), DTB_ADDR)
    else:
        if a.dtb:
            sys.exit("header v3 carries no DTB; it comes from vendor_boot")
        img = build_v3(kernel, ramdisk, cmdline)
        extra = "dtb from vendor_boot"

    open(a.out, "wb").write(img)
    print("PACKED %s (%d B) v%d: kernel %d @%#x, ramdisk %d @%#x, %s"
          % (a.out, len(img), a.header_version, len(kernel), KERNEL_ADDR,
             len(ramdisk), RAMDISK_ADDR, extra))


if __name__ == "__main__":
    main()
