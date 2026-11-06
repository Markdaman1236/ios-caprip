#!/bin/bash
# Build the first-userspace binary: tools/sweet-init.S wrapped by
# tools/mkinit.py into a static, ad-hoc signed arm64 Mach-O.
#
# xnu's mockfs serves a bare Mach-O memory disk as /sbin/launchd, so this
# alone is a bootable "root": pass it to mkpayload.py --ramdisk and boot
# with rd=md0. No filesystem needed for this milestone.
set -euo pipefail
P="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/port"
O="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/build/init"
cd "$P"
mkdir -p "$O"

echo "### assembling sweet-init.S for arm64-apple-ios16.0"
clang -target arm64-apple-ios16.0 -c tools/sweet-init.S -o "$O/init.o"
ls -l "$O/init.o"
file "$O/init.o" 2>/dev/null || true

echo "### wrapping into a static ad-hoc signed Mach-O"
python3 tools/mkinit.py "$O/init.o" "$O/launchd"
ls -l "$O/launchd"

echo "### verifying the result"
command -v llvm-objdump-18 >/dev/null && OD=llvm-objdump-18 || OD=llvm-objdump
$OD --macho --all-headers "$O/launchd" 2>/dev/null \
  | grep -E 'magic|cputype|filetype|ncmds|cmd |segname|vmaddr|entryoff|pc ' | head -30
