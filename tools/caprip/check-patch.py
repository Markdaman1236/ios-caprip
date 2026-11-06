#!/usr/bin/env python3
"""Structural validation for a unified diff, before it costs a CI round trip.

A malformed patch is silently skipped by the build ("Skipping patch ...
malformed"), the kernel builds anyway without it, and the only symptom is a
missing feature. That is how upstream lost patch 0080, and how the first
version of 0028b was lost: a C string literal containing a backslash-n was
emitted as a real newline, which split a context line in two and left a line
starting with a quote character. git reported "corrupt patch at line 19".

Checks:
  1. every line inside a hunk starts with ' ', '+', '-' or '\\'
  2. the declared @@ counts match the actual context/added/removed lines
  3. every hunk belongs to a file header, and every file header has a hunk

Exit status is non-zero if anything is wrong.

    check-patch.py PATCH [PATCH ...]
"""
import re
import sys

HUNK = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')


def check(path):
    with open(path, encoding='utf-8', newline='') as f:
        lines = f.read().split('\n')
    if lines and lines[-1] == '':
        lines = lines[:-1]

    problems = []
    hunks = 0
    in_hunk = False
    want_old = want_new = 0
    got_old = got_new = 0
    cur_file = None

    def close_hunk(at):
        if not in_hunk:
            return
        if got_old != want_old or got_new != want_new:
            problems.append(
                'line %d: hunk for %s declares %d/%d but contains %d/%d'
                % (at, cur_file, want_old, want_new, got_old, got_new))

    for n, ln in enumerate(lines, 1):
        m = HUNK.match(ln)
        if m:
            close_hunk(n)
            hunks += 1
            in_hunk = True
            want_old = int(m.group(2) or 1)
            want_new = int(m.group(4) or 1)
            got_old = got_new = 0
            continue
        if ln.startswith('diff --git '):
            close_hunk(n)
            in_hunk = False
            cur_file = ln.split(' b/')[-1]
            continue
        if not in_hunk:
            continue
        if ln.startswith('--- ') or ln.startswith('+++ '):
            # file headers only legally appear before the first hunk
            problems.append('line %d: file header inside a hunk' % n)
            continue
        c = ln[:1]
        if c == ' ':
            got_old += 1
            got_new += 1
        elif c == '+':
            got_new += 1
        elif c == '-':
            got_old += 1
        elif c == '\\':
            pass                        # "\ No newline at end of file"
        elif ln == '':
            # an empty context line: tolerated by git, but ambiguous
            got_old += 1
            got_new += 1
        else:
            problems.append(
                'line %d: bad prefix %r in a hunk -- a split line or a stray '
                'escape? %s' % (n, c, ln[:60]))
    close_hunk(len(lines))

    print('%s: %d hunks' % (path, hunks))
    for p in problems:
        print('  PROBLEM %s' % p)
    if not problems:
        print('  structurally OK')
    return not problems


if __name__ == '__main__':
    ok = True
    for a in sys.argv[1:]:
        ok &= check(a)
    sys.exit(0 if ok else 1)
