#!/bin/bash
# Validate 0028b before spending a CI round trip:
#   1. structural check (every hunk line has a legal prefix, counts match)
#   2. a real `git apply --check` against a synthetic tree holding exactly
#      the context the patch expects (the state patch 0028 leaves behind)
#
# The synthetic files are written by python3, not shell printf: a C string
# literal here contains a backslash-n, and every attempt to carry that
# through shell quoting has turned it into a real newline -- which is the
# very bug this check exists to catch.
set -u
P="/mnt/c/Users/Mark Sandor/Documents/rea/ios_G30/port"
PATCH="$P/xnu/patches/0028b-sweet-emmc-root-device.patch"

echo "### structural check"
python3 "$P/tools/caprip/check-patch.py" "$PATCH" || exit 1

echo
echo "### building a synthetic tree with the expected post-0028 context"
W=$(mktemp -d)
cd "$W" || exit 1
git init -q .
python3 - "$W" <<'PY'
import os, sys
BS = chr(92)
root = sys.argv[1]
os.makedirs(os.path.join(root, 'bsd/conf'), exist_ok=True)
os.makedirs(os.path.join(root, 'iokit/bsddev'), exist_ok=True)

files = ['filler %d' % i for i in range(1, 104)] + [
    'bsd/dev/random/randomdev.c\t\tstandard',
    '',
    'bsd/dev/memdev.c\t\t\tstandard',
    'bsd/dev/sweet_ufs.c\t\t\tstandard',
    'bsd/dev/mem.c\t\t\t\tstandard',
    'bsd/dev/munge.c \t\t\toptional config_requires_u32_munging',
    'bsd/dev/unix_startup.c\t\t\tstandard',
]
open(os.path.join(root, 'bsd/conf/files'), 'w', newline='\n').write(
    '\n'.join(files) + '\n')

init = ['// filler %d' % i for i in range(1, 784)] + [
    '\t\tstrlcpy(rootName, rdBootVar, rootNameSize);',
    '\t\tIOLog("BSD root: %s, major %d, minor %d' + BS + 'n", rootName, '
    'major(*root), minor(*root));',
    '\t\t*oflags = 0;',
    '\t\tgoto iofrootx;',
    '\t}',
    '#endif',
    '',
    '//',
    '//\tNow check if we are trying to root on a memory device',
    '//',
]
open(os.path.join(root, 'iokit/bsddev/IOKitBSDInit.cpp'), 'w',
     newline='\n').write('\n'.join(init) + '\n')
print('  synthetic tree written')
PY

git add -A >/dev/null
git -c user.email=a@b -c user.name=c commit -qm base

echo
echo "### git apply --check"
if git apply --check -v "$PATCH" 2>&1 | sed 's/^/  /'; then
	echo "  RESULT: PASS"
	git apply "$PATCH"
	echo "### applied; what it produced:"
	grep -n 'sweet_emmc' bsd/conf/files | sed 's/^/  /'
	grep -n 'emmcroot0' iokit/bsddev/IOKitBSDInit.cpp | head -3 | sed 's/^/  /'
	echo "  new file: $(wc -l < bsd/dev/sweet_emmc.c) lines"
	rc=0
else
	echo "  RESULT: FAIL"
	rc=1
fi
cd /
rm -rf "$W"
exit $rc
