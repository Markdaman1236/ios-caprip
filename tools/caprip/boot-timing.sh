#!/bin/bash
# Boot the image, then watch how long the device stays away from fastboot.
#   away ~0s        -> ABL never transferred control
#   away ~200s      -> shim ran, hit a loader error, waited 3m20s, reset
#   never returns   -> xnu took over (or a hard hang)
export PATH="/c/platform-tools:$PATH"
cd "/c/Users/Mark Sandor/Documents/rea/ios_G30/port"
IMG=${1:-out/xnu-caprip.img}
echo "image: $IMG"
t0=$(date +%s)
fastboot boot "$IMG" 2>&1
echo "[$(( $(date +%s) - t0 ))s] fastboot boot returned"
prev=present
for i in $(seq 1 120); do
  if fastboot devices 2>/dev/null | grep -q fastboot; then cur=present; else cur=absent; fi
  if [ "$cur" != "$prev" ]; then
    echo "[$(( $(date +%s) - t0 ))s] device $cur in fastboot"
    prev=$cur
  fi
  sleep 2
done
echo "[$(( $(date +%s) - t0 ))s] final: $prev"
