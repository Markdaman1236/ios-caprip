#!/bin/bash
# Build the real iOS root: one case-sensitive, journaled HFS+ image holding
# the OS volume plus both cryptexes.
#
# 181,700 files / 10.86 GB, all read back through apfs-fuse (which also
# decompresses LZBITMAP), so this is slow.
#
# Steps mirror what the port expects of the image:
#   - OS volume at /, cryptexes under /private/preboot/Cryptexes/{OS,App}
#   - the SystemOS cryptex's dyld shared cache hard-linked into
#     /System/Library/Caches/com.apple.dyld, where dyld looks at
#     ignition level 1 (hard links, so no extra space)
#   - every cryptex file with no counterpart in the OS root hard-linked to
#     its root path, because dyld does not search the cryptexes at that
#     level (libobjc-trampolines, libffi-trampolines, libstdc++ ...).
#     Linux hfsplus cannot hard-link a symlink, so symlinks are copied.
#   - logd's stores, normally created at restore: owner _logd (272) plus a
#     .migrated marker, else libtrace aborts with
#     "BUG IN LIBTRACE: Failed to migrate directory"
#   - a plain-plist system keybag for the built-in AppleKeyStore
set -u

E="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/ipsw-extract"
FINAL="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/iosroot.img"
SIZE=16G

OS_DMG="$E/087-86698-044.dmg"
SYS_DMG="$E/087-86593-047.dmg"
APP_DMG="$E/087-86715-047.dmg"

for f in "$OS_DMG" "$SYS_DMG" "$APP_DMG"; do
	[ -f "$f" ] || { echo "missing $f"; exit 1; }
done
[ -e "$FINAL" ] && { echo "refusing to overwrite $FINAL"; ls -l "$FINAL"; exit 1; }

# /usr/lib/modules/<ver> is an overlay WSL rebuilds on every boot, so a
# depmod-installed module does not survive a restart. Load the one left in
# the build tree by absolute path instead.
if ! grep -q hfsplus /proc/filesystems; then
	modprobe hfsplus 2>/dev/null ||
		insmod /usr/src/wsl-kernel/fs/hfsplus/hfsplus.ko 2>/dev/null
fi
grep -q hfsplus /proc/filesystems || {
	echo "hfsplus not available; build it with build/build-hfsplus3.sh"
	exit 1
}
echo "### hfsplus loaded"
command -v apfs-fuse >/dev/null || { echo "apfs-fuse missing"; exit 1; }
command -v rsync    >/dev/null || apt-get install -y -qq rsync 2>&1 | tail -1
command -v mkfs.hfsplus >/dev/null || apt-get install -y -qq hfsprogs 2>&1 | tail -1

# Build on the WSL filesystem when there is room: a 16 GB image taking
# random writes over drvfs (/mnt/c) is far slower. Copy across at the end.
avail=$(df -BG --output=avail /var/tmp | tail -1 | tr -dc '0-9')
if [ "${avail:-0}" -ge 24 ]; then
	OUT=/var/tmp/iosroot.img
	echo "### building on ext4 (/var/tmp), ${avail}G free; will copy to /mnt/c at the end"
else
	OUT="$FINAL"
	echo "### only ${avail}G free in /var/tmp; building directly on /mnt/c (slower)"
fi
[ -e "$OUT" ] && rm -f "$OUT"

WORK=$(mktemp -d)
mounts=()
cleanup() {
	local busy=0 m
	for m in "${mounts[@]:-}"; do
		[ -n "$m" ] || continue
		mountpoint -q "$m" && umount "$m" 2>/dev/null
		mountpoint -q "$m" && busy=1
	done
	if [ "$busy" = 0 ]; then
		rm -f "$WORK"/*.dmg
		rmdir "$WORK"/* "$WORK" 2>/dev/null
	else
		echo "still mounted under $WORK: left in place" >&2
	fi
}
trap cleanup EXIT

# apfs-fuse splits -o options on ',', which iPhone10,3 paths contain, so go
# through links; and it only parses UDIF when the name ends in .dmg.
apfs_mount() {
	ln -sf "$1" "$WORK/$2.dmg"
	mkdir -p "$WORK/$2"
	apfs-fuse -o ro,allow_other "$WORK/$2.dmg" "$WORK/$2" || return 1
	sleep 1
	mountpoint -q "$WORK/$2" || { echo "failed to mount $2"; return 1; }
	mounts+=("$WORK/$2")
	echo "  mounted $2"
}
echo "### mounting the APFS payloads"
apfs_mount "$OS_DMG"  os    || exit 1
apfs_mount "$SYS_DMG" sysos || exit 1
apfs_mount "$APP_DMG" appos || exit 1

echo "### creating the HFS+ volume ($SIZE, case-sensitive, journaled)"
truncate -s "$SIZE" "$OUT"
mkfs.hfsplus -s -J -v iOSRoot "$OUT" >/dev/null || { echo "mkfs failed"; exit 1; }
mkdir -p "$WORK/root"
mount -t hfsplus -o loop,force,rw "$OUT" "$WORK/root" || { echo "mount failed"; exit 1; }
mountpoint -q "$WORK/root" || { echo "root not mounted"; exit 1; }
mounts=("$WORK/root" "${mounts[@]}")

copy() {
	echo "### copying $1 -> ${2#"$WORK/root"}/"
	mkdir -p "$2"
	rsync -aH --numeric-ids --info=progress2 --no-inc-recursive "$1/" "$2/" 2>&1 | tail -3
}
date
copy "$WORK/os/root"    "$WORK/root"
copy "$WORK/sysos/root" "$WORK/root/private/preboot/Cryptexes/OS"
copy "$WORK/appos/root" "$WORK/root/private/preboot/Cryptexes/App"
date

echo "### hard-linking the shared cache where dyld looks at ignition level 1"
dsc="$WORK/root/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
mkdir -p "$WORK/root/System/Library/Caches/com.apple.dyld"
n=0
for f in "$dsc"/*; do
	[ -e "$f" ] || continue
	ln -f "$f" "$WORK/root/System/Library/Caches/com.apple.dyld/${f##*/}" && n=$((n+1))
done
echo "  linked $n shared-cache files"

echo "### hard-linking cryptex files with no OS-root counterpart"
for c in OS App; do
	base="$WORK/root/private/preboot/Cryptexes/$c"
	[ -d "$base" ] || continue
	cnt=0
	while IFS= read -r f; do
		f=${f#./}
		[ -n "$f" ] || continue
		if [ ! -e "$WORK/root/$f" ] && [ ! -L "$WORK/root/$f" ]; then
			mkdir -p "$WORK/root/$(dirname "$f")"
			src="$base/$f"
			# Linux hfsplus cannot hard-link a symlink: copy those.
			if [ -L "$src" ]; then cp -P "$src" "$WORK/root/$f"
			else ln "$src" "$WORK/root/$f" 2>/dev/null || cp -P "$src" "$WORK/root/$f"
			fi
			cnt=$((cnt+1))
		fi
	done < <(cd "$base" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*')
	echo "  cryptex $c: linked $cnt files"
done

echo "### logd stores (owner _logd 272 + .migrated marker)"
db="$WORK/root/private/var/db"
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

echo "### system keybag (no passcode)"
install -d -m 0700 -o 0 -g 0 "$WORK/root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' \
	| install -m 0600 -o 0 -g 0 /dev/stdin "$WORK/root/private/var/keybags/systembag.kb"

echo "### result"
df -h "$WORK/root" | tail -1
echo "  launchd:  $(ls -l "$WORK/root/sbin/launchd" 2>&1 | awk '{print $5, $NF}')"
echo "  dyld:     $(ls -l "$WORK/root/usr/lib/dyld" 2>&1 | awk '{print $5, $NF}')"
echo "  caches:   $(ls -1 "$WORK/root/System/Library/Caches/com.apple.dyld" 2>/dev/null | wc -l) files"

umount "$WORK/root"
mounts=("${mounts[@]:1}")

echo "### fsck (hfsplus decomposes some non-ASCII names differently; let it rewrite, then verify)"
fsck.hfsplus -f -y "$OUT" 2>&1 | grep -v 'Illegal name' | tail -5
fsck.hfsplus -f -n "$OUT" 2>&1 | tail -5

if [ "$OUT" != "$FINAL" ]; then
	echo "### copying to $FINAL"
	date
	cp "$OUT" "$FINAL" && rm -f "$OUT"
	date
fi
ls -l "$FINAL"
echo "### DONE"
