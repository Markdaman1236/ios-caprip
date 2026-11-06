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
CMD="debug=0xc serial=3 cpus=${CPUS:-4} keepsyms=1 -noprogress rd=md0 sweettouch=0 sweethw=0 sweetfb_noconsole=0 sweetfb_hz=30"
python3 tools/mkpayload.py "$KERNEL" "$OUT/caprip.adt" "$OUT/payload.bin" \
    --cmdline "$CMD" ${RAMDISK:+--ramdisk "$RAMDISK"}

# --- 3. shim, built for caprip's panel ------------------------------------
# FB_* land in boot_args.Video, which is where xnu's AppleCLCD reads the
# geometry from -- a wrong stride here skews the entire iOS surface.
# SCALE=2: at 720 px, SCALE 3 leaves only 29 columns and clips the
# diagnostics that make a failed boot readable.
EXTRA_CFLAGS="-DFB_W=720 -DFB_H=1600 -DFB_STRIDE=2880 -DSCALE=2 -DNO_UFS_PROBE" \
    MKBOOTIMG=/bin/true shim/build.sh >/dev/null 2>&1 || true
[ -s shim/out/Image ] || { echo "error: shim did not build; run shim/build.sh to see why" >&2; exit 1; }
cp shim/out/Image "$OUT/shim.bin"

# loader.c looks for the payload at the first 4K boundary after _end.
size=$(stat -c%s "$OUT/shim.bin")
truncate -s $(( (size + 4095) / 4096 * 4096 )) "$OUT/shim.bin"
cat "$OUT/shim.bin" "$OUT/payload.bin" > "$OUT/Image"
gzip -9 -f -k "$OUT/Image"

# --- 4. pack ---------------------------------------------------------------
# caprip's stock kernel is itself gzipped, so ABL's gunzip path is proven.
# The raw image is packed too, as a fallback if that path misbehaves.
for variant in gz raw; do
    case $variant in
        gz)  img="$OUT/Image.gz"; out="$OUT/xnu-caprip.img" ;;
        raw) img="$OUT/Image";    out="$OUT/xnu-caprip-raw.img" ;;
    esac
    python3 tools/mkboot_caprip.py \
        --kernel "$img" \
        --dtb tools/caprip/sm6115-motorola-caprip.dtb \
        --ramdisk "$OUT/ramdisk.bin" \
        --cmdline "$CMD" \
        --header-version 2 \
        -o "$out"
done

ls -l "$OUT"/xnu-caprip*.img
cat <<'EOT'

Boot it from RAM (writes nothing):
    fastboot boot out/xnu-caprip.img
Fallback if ABL refuses the gzipped kernel:
    fastboot boot out/xnu-caprip-raw.img
EOT
