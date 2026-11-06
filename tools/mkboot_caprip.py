#!/usr/bin/env python3
"""Pack a caprip (Motorola moto g30, SM6115 bengal) XNU boot image - stdlib only.

caprip ships boot header v3. In that layout boot.img carries neither the DTB
nor the load addresses: ABL takes both from vendor_boot. That is also why
`fastboot boot` has no vendor_boot argument -- ABL pairs the RAM-booted
boot.img with the vendor_boot already on flash in the active slot, which
hands us a valid caprip DTB for free.

  --header-version 3  (default)  caprip's native layout. DTB and load
        addresses come from the on-flash vendor_boot. This is the one that
        matches how the device actually boots.
  --header-version 4             v3 plus the signature_size field.
  --header-version 2             Self-contained: load addresses and DTB live
        in the image. Proven on gta4l (same SoC), but caprip's ABL rejects
        it -- it returns to fastboot after ~2 s without running the kernel.

The geometry below was read out of caprip's live vendor_boot_a header and is
only used by the v2 layout.

Everything here is for `fastboot boot`, which runs from RAM and writes
nothing to the device.
"""
import argparse
import gzip
import io
import struct
import sys

PAGE = 4096
KERNEL_ADDR = 0x00008000
RAMDISK_ADDR = 0x01000000
TAGS_ADDR = 0x00000100
DTB_ADDR = 0x01F00000
HDR_V2_SIZE = 1660
HDR_V3_SIZE = 1580
HDR_V4_SIZE = 1584
FDT_MAGIC = b"\xd0\x0d\xfe\xed"
# caprip's stock boot_a os_version word: Android 11.0.0, patch level 2024-02.
# Reused verbatim in case ABL or AVB sanity-checks the patch level.
OS_VERSION = 0x16000982


def pad(data, page=PAGE):
    return data + b"\0" * (-len(data) % page)


def check_dtb(path):
    dtb = open(path, "rb").read()
    if dtb[:4] != FDT_MAGIC:
        sys.exit("%s: not a flattened device tree" % path)
    total = struct.unpack_from(">I", dtb, 4)[0]
    if total != len(dtb):
        sys.exit("%s: totalsize %d != file size %d (truncated?)"
                 % (path, total, len(dtb)))
    for prop in (b"qcom,msm-id", b"qcom,board-id"):
        if prop not in dtb:
            sys.exit("%s: missing %s; ABL will reject it" % (path, prop.decode()))
    return dtb


def empty_ramdisk():
    """A valid gzipped newc cpio holding only the TRAILER record.

    ABL dislikes a zero-length ramdisk on some builds, and for us the ramdisk
    is dead weight anyway: the xnu payload rides inside the kernel Image
    (loader.c's EMBED path), not in the ramdisk.
    """
    name = b"TRAILER!!!\0"
    fields = [0] * 13
    fields[4] = 1                                     # nlink
    fields[11] = len(name)                            # namesize
    rec = b"070701" + b"".join(b"%08X" % f for f in fields) + name
    rec += b"\0" * (-len(rec) % 4)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as g:
        g.write(rec)
    return buf.getvalue()


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
        OS_VERSION,
    )
    hdr[48:64] = name[:16].ljust(16, b"\0")
    hdr[64:576] = cmdline[:511].ljust(512, b"\0")
    struct.pack_into("<I", hdr, 1632, HDR_V2_SIZE)   # header_size
    struct.pack_into("<I", hdr, 1636, 0)             # recovery_dtbo_size
    struct.pack_into("<Q", hdr, 1640, 0)             # recovery_dtbo_offset
    struct.pack_into("<I", hdr, 1648, len(dtb))      # dtb_size
    struct.pack_into("<Q", hdr, 1652, DTB_ADDR)      # dtb_addr
    return pad(bytes(hdr)) + pad(kernel) + pad(ramdisk) + pad(dtb)


def build_v3v4(kernel, ramdisk, cmdline, version):
    size = HDR_V3_SIZE if version == 3 else HDR_V4_SIZE
    hdr = bytearray(size)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<4I", hdr, 8, len(kernel), len(ramdisk), OS_VERSION, size)
    # reserved[4] at 24..39 stays zero
    struct.pack_into("<I", hdr, 40, version)         # header_version
    hdr[44:44 + 1536] = cmdline[:1535].ljust(1536, b"\0")
    if version == 4:
        struct.pack_into("<I", hdr, 1580, 0)         # signature_size (unsigned)
    return pad(bytes(hdr)) + pad(kernel) + pad(ramdisk)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--dtb", help="board DTB (header v2 only)")
    ap.add_argument("--ramdisk", help="default: a generated empty cpio.gz")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--name", default="caprip-xnu")
    ap.add_argument("--header-version", type=int, default=3, choices=(2, 3, 4))
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read() if a.ramdisk else empty_ramdisk()
    cmdline = a.cmdline.encode()

    if a.header_version == 2:
        if not a.dtb:
            sys.exit("--dtb is required for header v2")
        dtb = check_dtb(a.dtb)
        img = build_v2(kernel, ramdisk, dtb, cmdline, a.name.encode())
        extra = "dtb %d @%#x" % (len(dtb), DTB_ADDR)
    else:
        if a.dtb:
            sys.exit("header v%d carries no DTB; it comes from vendor_boot"
                     % a.header_version)
        img = build_v3v4(kernel, ramdisk, cmdline, a.header_version)
        extra = "dtb from the on-flash vendor_boot of the active slot"

    open(a.out, "wb").write(img)
    print("PACKED %s (%d B) v%d: kernel %d, ramdisk %d, %s"
          % (a.out, len(img), a.header_version, len(kernel), len(ramdisk), extra))


if __name__ == "__main__":
    main()
