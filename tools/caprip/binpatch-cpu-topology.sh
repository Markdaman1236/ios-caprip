#!/bin/bash
# Apply patch 0080's semantics directly to the built kernel, because no
# macOS runner can be acquired to rebuild it.
#
#   0080:  if ((phys_id >> 8) > 1 || (phys_id & 0xff) > 3 || n > MAX) panic
#   0078:  if (phys_id > 0x700  || (phys_id & 0xff) != 0 || n > MAX) panic
#
# Three instruction rewrites, all in place, same lengths:
#   cmp w8,#0x700 -> cmp w8,#0x200   and  b.hi -> b.cs    gives (phys_id>>8)>1
#   and w8,#0xff  -> and w8,#0xfc                         gives (phys_id&0xff)>3
# The second works because 0..3 have no bits above bit1, so masking with
# 0xfc is exactly "> 3" for a byte.
set -euo pipefail
SRC="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/xnu-prebuilt/run-39498191206/kernel.development.sweet"
DST="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/xnu-prebuilt/kernel.development.caprip"
cp "$SRC" "$DST"

python3 - "$DST" <<'PY'
import struct, sys
path = sys.argv[1]
d = bytearray(open(path, 'rb').read())

ncmds = struct.unpack_from('<I', d, 16)[0]
off, seg = 32, None
for _ in range(ncmds):
    cmd, csz = struct.unpack_from('<2I', d, off)
    if cmd == 0x19:
        name = bytes(d[off+8:off+24]).rstrip(b'\0').decode()
        vmaddr, vmsize, fo, fs = struct.unpack_from('<4Q', d, off+24)
        if name == '__TEXT_EXEC':
            seg = (vmaddr, fo)
    off += csz
vmaddr, fileoff = seg

# (virtual address, expected current word, replacement, description)
edits = [
    (0xfffffe0007aba288, 0x711c011f, 0x7108011f, 'cmp w8, #0x700  ->  cmp w8, #0x200'),
    (0xfffffe0007aba28c, 0x54000c88, 0x54000c82, 'b.hi .+0x190    ->  b.cs .+0x190'),
    (0xfffffe0007aba290, 0x12001d08, 0x121e1508, 'and w8,w8,#0xff ->  and w8,w8,#0xfc'),
]
for va, want, new, desc in edits:
    fo = fileoff + (va - vmaddr)
    cur = struct.unpack_from('<I', d, fo)[0]
    if cur != want:
        sys.exit('REFUSING: at %#x (file %d) expected %#010x, found %#010x' % (va, fo, want, cur))
    struct.pack_into('<I', d, fo, new)
    print('  %#x  %#010x -> %#010x   %s' % (va, want, new, desc))

open(path, 'wb').write(bytes(d))
print('wrote', path, len(d), 'bytes')
PY

echo
echo "### verify by disassembling the patched region"
python3 - "$DST" /tmp/patched.bin <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]
off, seg = 32, None
for _ in range(ncmds):
    cmd, csz = struct.unpack_from('<2I', d, off)
    if cmd == 0x19:
        name = d[off+8:off+24].rstrip(b'\0').decode()
        vmaddr, vmsize, fo, fs = struct.unpack_from('<4Q', d, off+24)
        if name == '__TEXT_EXEC':
            seg = (vmaddr, fo)
    off += csz
vmaddr, fileoff = seg
S = 0xfffffe0007aba280
open(sys.argv[2], 'wb').write(d[fileoff + (S - vmaddr): fileoff + (S - vmaddr) + 0x30])
PY
aarch64-linux-gnu-objdump -D -b binary -m aarch64 --adjust-vma=0xfffffe0007aba280 /tmp/patched.bin 2>&1 | sed -n '7,20p'
