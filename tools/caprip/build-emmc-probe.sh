#!/bin/bash
# Build the eMMC bring-up image: shim only, -DEMMC_PROBE, no xnu payload.
set -euo pipefail
S="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/port/shim"
P="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/port"
O="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/build/emmc-out"
mkdir -p "$O"
CC=aarch64-linux-gnu-gcc
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align
        -fno-stack-protector -Wall -Wextra
        -DFB_W=720 -DFB_H=1600 -DFB_STRIDE=2880 -DSCALE=2
        -DNO_UFS_PROBE -DEMMC_PROBE"
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c emmc.c; do
    echo "CC $f"
    $CC $CFLAGS -I"$S" -c "$S/$f" -o "$O/${f%.*}.o"
done
abs=$(aarch64-linux-gnu-readelf -r "$O"/shim.o "$O"/console.o "$O"/mmu.o \
        "$O"/fdt.o "$O"/loader.o "$O"/ufs.o "$O"/emmc.o | grep -c ABS64 || true)
echo "ABS64 relocations: $abs (must be 0)"
[ "$abs" = 0 ] || { echo "error: absolute relocations present" >&2; exit 1; }
$CC $CFLAGS -static -T "$S/shim.ld" -Wl,--build-id=none \
    -Wl,--no-warn-rwx-segments -Wl,-N \
    "$O"/start.o "$O"/shim.o "$O"/console.o "$O"/mmu.o "$O"/fdt.o \
    "$O"/loader.o "$O"/ufs.o "$O"/emmc.o -o "$O/shim.elf"
aarch64-linux-gnu-objcopy -O binary "$O/shim.elf" "$O/Image"
size=$((16#$(aarch64-linux-gnu-nm "$O/shim.elf" | awk '$3=="_end"{print $1}')))
truncate -s "$size" "$O/Image"
gzip -9 -f -k "$O/Image"
echo "_end = $size"
python3 "$P/tools/mkboot_caprip.py" --kernel "$O/Image.gz" \
    --cmdline "emmc probe" --header-version 3 -o "$P/out/xnu-caprip-emmc.img"
ls -l "$P/out/xnu-caprip-emmc.img"
