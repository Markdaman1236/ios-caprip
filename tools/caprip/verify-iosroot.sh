#!/bin/bash
# Verify the image properly: fsck, then compare real content hashes against
# the APFS source. A file count alone proved insufficient last time.
set -u
E="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/ipsw-extract"
IMG="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/iosroot.img"
W=/tmp/vfy
grep -q hfsplus /proc/filesystems || insmod /usr/src/wsl-kernel/fs/hfsplus/hfsplus.ko

echo "### fsck after the write pass"
fsck.hfsplus -f -y "$IMG" 2>&1 | grep -v 'Illegal name' | tail -4

rm -rf $W; mkdir -p $W/os $W/sysos $W/img
ln -sf "$E/087-86698-044.dmg" $W/os.dmg
ln -sf "$E/087-86593-047.dmg" $W/sysos.dmg
apfs-fuse -o ro,allow_other $W/os.dmg $W/os || exit 1
apfs-fuse -o ro,allow_other $W/sysos.dmg $W/sysos || exit 1
sleep 2
mount -t hfsplus -o loop,force,ro "$IMG" $W/img || exit 1

echo
echo "### content hashes: image vs APFS source"
ok=0; bad=0
for p in sbin/launchd usr/lib/dyld usr/libexec/xpcproxy bin/ps bin/df \
         System/Library/CoreServices/SpringBoard.app/SpringBoard \
         usr/lib/libSystem.B.dylib; do
  if [ -f "$W/img/$p" ] && [ -f "$W/os/root/$p" ]; then
    a=$(md5sum < "$W/img/$p" | cut -d' ' -f1)
    b=$(md5sum < "$W/os/root/$p" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then printf '  MATCH   %-56s %s\n' "$p" "$(stat -c%s "$W/img/$p")"; ok=$((ok+1))
    else printf '  DIFFER  %s\n' "$p"; bad=$((bad+1)); fi
  elif [ -f "$W/img/$p" ]; then printf '  in image only %s\n' "$p"
  else printf '  MISSING %s\n' "$p"; bad=$((bad+1)); fi
done
echo "  matched=$ok problems=$bad"

echo
echo "### the one file that failed to read from APFS (sysos libstdc++)"
ls -l "$W/img/private/preboot/Cryptexes/OS/usr/lib/libstdc++.6.0.9.dylib" 2>&1 | head -1
ls -l "$W/img/usr/lib/libstdc++.6.0.9.dylib" 2>&1 | head -1

echo
echo "### dyld shared cache in the image"
ls -1 "$W/img/System/Library/Caches/com.apple.dyld" 2>/dev/null | wc -l
du -sh "$W/img/System/Library/Caches/com.apple.dyld" 2>/dev/null | cut -f1

echo
echo "### totals"
echo "  files:    $(find $W/img -type f 2>/dev/null | wc -l)"
echo "  symlinks: $(find $W/img -type l 2>/dev/null | wc -l)"
df -h $W/img | tail -1
umount $W/img; umount $W/os; umount $W/sysos
