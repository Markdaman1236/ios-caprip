#!/bin/bash
# Build a caprip (Motorola moto g(30), SM6115 "bengal") XNU boot image:
# shim + fixup-resolved payload + ADT, packed as Android header v2 with
# caprip's own board DTB.
#
#   tools/build_caprip.sh kernel.development.sweet [ramdisk.img]
#
# Everything here is non-destructive: the result is meant for
# `fastboot boot`, which runs from RAM and writes nothing to the device.
#
# Hardware facts (all verified on the device, see NOTES-caprip.md):
#   panel        720x1600, stride 2880, framebuffer 0x5C000000 (15 MiB)
#   RAM window   0xC0000000 + 0x80000000  (above every fixed carve-out)
#   CPUs         4 usable: Gold A73 cores, MPIDR 0x100..0x103
#                (the 4 Silver A53s lack the 16K granule xnu needs)
#   storage      eMMC at 0x04744000; UFS at 0x04800000 is UNCLOCKED - any
#                MMIO read there bus-faults and reboots, so no UFS node and
#                no UFS probe (-DNO_UFS_PROBE).
set -euo pipefail
cd "$(dirname "$0")/.."
KERNEL=${1:?usage: tools/build_caprip.sh kernel.development.sweet [ramdisk.img]}
RAMDISK=${2:-}
OUT=${OUT:-out}
mkdir -p "$OUT"
[ -f "$OUT/ramdisk.bin" ] || printf '\0\0\0\0\0' > "$OUT/ramdisk.bin"

# --- 1. Apple device tree -------------------------------------------------
DEVICE=caprip PHYSBASE=${PHYSBASE:-0xc0000000} MEMSIZE=${MEMSIZE:-0x80000000} \
    python3 tools/mkadt.py "$OUT/caprip.adt" --native

# --- 2. xnu payload (segments + ADT + cmdline, chained fixups resolved) ---
# cpus=4: the Gold cluster only. sweettouch/sweethw off for the first boot;
# the console on the panel is the whole point of this milestone.
# ROOTDEV picks what xnu mounts as /:
#   md0        -- mockfs memory disk (the heartbeat-only milestone build)
#   emmcroot0  -- bsd/dev/sweet_emmc.c, the real HFSX volume on eMMC
# IOFindBSDRoot matches the rd= string, so this is the only switch needed;
# the /sweet-emmc ADT node is already emitted for DEVICE=caprip.
ROOTDEV=${ROOTDEV:-md0}
CMD="debug=0xc serial=3 cpus=${CPUS:-4} keepsyms=1 -noprogress rd=$ROOTDEV sweettouch=0 sweethw=0 sweetfb_noconsole=0 sweetfb_hz=30"
python3 tools/mkpayload.py "$KERNEL" "$OUT/caprip.adt" "$OUT/payload.bin" \
    --cmdline "$CMD" ${RAMDISK:+--ramdisk "$RAMDISK"}

# --- 3. shim, built for caprip's panel ------------------------------------
# FB_* land in boot_args.Video, which is where xnu's AppleCLCD reads the
# geometry from -- a wrong stride here skews the entire iOS surface.
# SCALE=2: at 720 px, SCALE 3 leaves only 29 columns and clips the
# diagnostics that make a failed boot readable.
# SHIM_EXTRA appends to the shim flags; -DEMMC_PROBE builds the storage
# bring-up image, which reports on the panel and never loads xnu.
EXTRA_CFLAGS="-DFB_W=720 -DFB_H=1600 -DFB_STRIDE=2880 -DSCALE=2 -DNO_UFS_PROBE ${SHIM_EXTRA:-}" \
    MKBOOTIMG=/bin/true shim/build.sh >/dev/null 2>&1 || true
[ -s shim/out/Image ] || { echo "error: shim did not build; run shim/build.sh to see why" >&2; exit 1; }
cp shim/out/Image "$OUT/shim.bin"

# loader.c looks for the payload at the first 4K boundary after _end.
size=$(stat -c%s "$OUT/shim.bin")
truncate -s $(( (size + 4095) / 4096 * 4096 )) "$OUT/shim.bin"
cat "$OUT/shim.bin" "$OUT/payload.bin" > "$OUT/Image"
gzip -9 -f -k "$OUT/Image"

# --- 4. pack ---------------------------------------------------------------
# MEASURED on caprip: ABL *rejects* a header v2 image -- it returns to
# fastboot after ~2 s without ever running the kernel. Header v3 (caprip's
# native layout) works: ABL pairs our RAM-booted boot.img with the
# vendor_boot already on flash, which supplies a valid caprip DTB for free.
# That is also why `fastboot boot` takes no vendor_boot argument.
#
# caprip's stock kernel is itself gzipped, so ABL's gunzip path is proven.
python3 tools/mkboot_caprip.py --kernel "$OUT/Image.gz" --cmdline "$CMD" \
    --header-version 3 -o "$OUT/xnu-caprip.img"
python3 tools/mkboot_caprip.py --kernel "$OUT/Image.gz" --cmdline "$CMD" \
    --header-version 4 -o "$OUT/xnu-caprip-v4.img"
python3 tools/mkboot_caprip.py --kernel "$OUT/Image" --cmdline "$CMD" \
    --header-version 3 -o "$OUT/xnu-caprip-raw.img"
python3 tools/mkboot_caprip.py --kernel "$OUT/Image.gz" --cmdline "$CMD" \
    --dtb tools/caprip/sm6115-motorola-caprip.dtb \
    --header-version 2 -o "$OUT/xnu-caprip-v2.img"

ls -l "$OUT"/xnu-caprip*.img
echo
echo "Boot it from RAM (writes nothing):"
echo "    fastboot boot out/xnu-caprip.img        # header v3 -- the one that works"
echo "Alternatives:"
echo "    fastboot boot out/xnu-caprip-v4.img     # v3 + signature_size field"
echo "    fastboot boot out/xnu-caprip-raw.img    # uncompressed kernel"
echo "    fastboot boot out/xnu-caprip-v2.img     # self-contained; ABL rejects it"
echo
echo "Recover at any time by holding Power for ~10 s: nothing was flashed."
