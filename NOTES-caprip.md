# caprip notes

Motorola moto g(30), `caprip`, SM6115 "bengal" (Snapdragon 662), 4 GB.
Branch `caprip` of `Markdaman1236/ios-caprip`, forked from `NoNameBuilder/ios-topaz`
(which targets `gta4l`, Galaxy Tab A7 -- the same SoC).

Target: iOS 16.7.16, build `20H392`, presented as `iPhone10,3` (D22AP).

## Why this was cheap

caprip and gta4l are both SM6115. Every SoC-level address in the shim was
already right; only the panel, the RAM window and the boot-image format are
caprip-specific. Independent verification against the live device tree:

| value | gta4l | caprip (measured) |
|---|---|---|
| `qcom,msm-id` | `0x1bc 0x10000` | `0x1a1 0x10000 0x1bc 0x10000` |
| GICD / GICR | `0x0F200000` / `0x0F300000` | identical |
| splash framebuffer | `0x5C000000` | identical (15 MiB) |
| eMMC (SDHCI) | `0x04744000` | identical |
| generic timer | 19.2 MHz, vtimer INTID 19 | identical |
| GENI UART | `0x04A90000` IRQ 363 | identical |

## Hardware facts (verified on the device)

- **Panel** 720x1600, stride 2880, a8r8g8b8. Framebuffer is the ABL splash
  region `cont_splash_region@5c000000`, reg `<0x5C000000 0x00F00000>` (15 MiB);
  720*1600*4 = 4.4 MiB fits. Confirmed by `wm size` and `/proc/device-tree`.
- **RAM** three banks: `0x40000000+0x3DD00000`, `0x80000000+0x40000000`,
  `0xC0000000+0x80000000`. Highest fixed carve-out ends at `0xAF0BF800`, so the
  kernel window is `PHYSBASE=0xC0000000 MEMSIZE=0x80000000` -- 2 GiB, aligned,
  above everything, ending exactly at the top of DDR.
- **CPUs** 8 present, **4 usable**. `cpu@0-3` are part `0x801` Kryo Silver
  (Cortex-A53), capacity `0x400`; `cpu@100-103` are part `0x800` Kryo Gold
  (Cortex-A73), capacity `0x666`. xnu needs the 16K translation granule and the
  A53s do not have it, so the Gold cluster is the whole machine: `cpus=4`,
  MPIDR `0x100..0x103`. ABL hands off on a Silver core, so the shim reads
  `ID_AA64MMFR0_EL1.TGran16`, and on 0 wakes Gold `0x100` with `PSCI_CPU_ON_64`
  and parks itself. The prebuilt kernel already carries this
  (`SWEET CPU: expected boot MPIDR 0x100 and logical CPU 0`).
- **Storage** eMMC 5.1 at `0x04744000` (sdhci-msm v5 + CQE). **The UFS block at
  `0x04800000` is unclocked: any MMIO read there bus-faults and reboots.**
  caprip's Android DT still carries a `ufshc@4804000` alias -- it is a trap, not
  a device. So: no `sweet-ufs` node in the ADT, and the shim is built
  `-DNO_UFS_PROBE` so that a *loader failure* leaves its message on screen
  instead of rebooting into the trap.
- **Serial** `earlycon=msm_geni_serial,0x4a90000`, `console=ttyMSM0,115200n8` --
  taken verbatim from caprip's stock `vendor_boot` cmdline. The UART is real and
  the stock kernel uses it; whether the board routes it to a reachable pad is
  not yet established.

## Boot image

caprip ships **header v3**, where `boot.img` carries neither DTB nor load
addresses -- ABL takes both from `vendor_boot`. The addresses below come from
caprip's own `vendor_boot_a` header:

    kernel  @0x00008000      ramdisk @0x01000000
    tags    @0x00000100      dtb     @0x01F00000      page 4096

`tools/mkboot_caprip.py` packs **header v2** instead: self-contained, carries
the addresses and the DTB, so `fastboot boot` needs nothing else. The DTB is
caprip's own, lifted out of `vendor_boot_a` (356,231 B, md5
`5eb27cd55b34078582982e3996ee6ab0`, `board-id = <0x0 0x0>`,
`msm-id = <0x1a1 0x10000 0x1bc 0x10000>`) -- guaranteed ABL-acceptable, because
it is what the device boots with every day.

caprip's stock kernel is itself gzipped, so ABL's gunzip path is proven; the
build emits a raw variant too as a fallback.

## Build

No fork of the kernel is needed for a first boot. The upstream `gta4l` build
artifacts are still live and the kernel is device-agnostic: panel geometry
reaches `AppleCLCD` through `boot_args.Video` (from `shim/console.h`) and the
ADT, and patch `0061` presents any panel <= 1125x2436 as an iPhone X with the
real panel centred -- which is exactly what 720x1600 wants.

```sh
gh run download 39498191206 -R NoNameBuilder/ios-topaz -n xnu-kernel -D xnu/out
tools/build_caprip.sh xnu/out/kernel.development.sweet
fastboot boot out/xnu-caprip.img          # RAM only; writes nothing
```

`fastboot boot` is non-destructive: nothing is flashed, and a power-button hold
returns the device to Android.

## Changes from upstream

- `shim/console.h` -- panel geometry overridable with `-DFB_W/-DFB_H/-DFB_STRIDE`.
  Not cosmetic: `loader.c` copies these into `boot_args.Video`, which is where
  xnu's `AppleCLCD` reads geometry from. A wrong stride skews the whole surface.
- `shim/console.c` -- `SCALE` overridable. At 720 px, SCALE 3 leaves 29 columns
  and silently clips the diagnostics; SCALE 2 gives 43.
- `shim/shim.c` -- `-DNO_UFS_PROBE` (see Storage above).
- `shim/build.sh` -- honours `EXTRA_CFLAGS`.
- `tools/mkadt.py` -- `DEVICE=` selects the panel (`caprip` = 720x1600); the
  `--native` canvas now follows the real panel instead of being hardcoded to
  sweet's 1080x2400 (a latent bug for gta4l too); the UFS node is omitted on
  bengal; `compatible` advertises `motorola,caprip` and `qcom,bengal`.
- `tools/mkboot_caprip.py`, `tools/build_caprip.sh`, `tools/caprip/` -- new.

## Verified state of the built image

    shim            184320 B (0x2D000), ARM64 Image header, 0 ABS64 relocs
    payload         SWEETXNU v1, 10 segments, at Image+0x2D000
    phys_base       0xC0000000   mem_size 0x80000000 (2 GiB)
    virt_base       0xFFFFFE0006000000   entry 0xFFFFFE00074A6488
    ADT             6832 B: fbcon 720x1600 stride 2880 @0x5C000000,
                    disp0 canvas 720x1600, no sweet-ufs node
    cmdline         debug=0xc serial=3 cpus=4 keepsyms=1 -noprogress rd=md0
                    sweettouch=0 sweethw=0 sweetfb_noconsole=0 sweetfb_hz=30
    xnu-caprip.img  6,336,512 B (gzipped kernel), header v2
    kernel          no LC_DYLD_CHAINED_FIXUPS -- "fixups: 0" is correct here,
                    not a silent failure (plain arm64, not arm64e)

## Result of the first boot attempt (2026-11-06)

**xnu boots on caprip.** `fastboot boot out/xnu-caprip.img` (header v3) runs the
shim, the loader succeeds, and xnu comes up far enough to render its own panic
screen on the panel -- the one that says to report the panic at
`panic.apple.com`. That it renders at all means `boot_args.Video` /
`AppleCLCD` have the right 720x1600 geometry. The panic itself is expected:
there is no root filesystem yet.

### Boot-image format: measured, not guessed

caprip's ABL **rejects header v2**, the format proven on gta4l. The signature is
unmistakable once you measure it:

| image | `fastboot boot` says | device away from fastboot | verdict |
|---|---|---|---|
| header v2 (with embedded DTB) | `Booting OKAY [10.76s]` | **2 s**, then back in fastboot | never ran |
| header v3 (DTB from flash) | `Booting OKAY [10.76s]` | **indefinitely**, USB gone entirely | ran |

`Booting OKAY` is not evidence of anything: ABL prints it either way. The useful
signal is how long the device stays away from fastboot, because the shim can
never return there quickly:

- `gold_main()` ends in `for (;;) wfe` on a loader failure -- it hangs, it does
  not reset.
- the Silver fallback path waits `delay_ms(180000)` + `reset(20)` = 3 min 20 s
  before rebooting to the bootloader.

So a return to fastboot within seconds proves ABL never transferred control,
and `tools/../build/boot-timing.sh` is the probe that distinguishes the cases.

Header v3 is caprip's native layout, and it needs no DTB in the image: ABL pairs
the RAM-booted `boot.img` with the `vendor_boot` already on flash in the active
slot. That is also why `fastboot boot` takes no vendor_boot argument.

## The first panic, and what it exposed

```
panic(cpu 0 caller 0xfffffe0007aba44c): SWEET CPU: invalid topology
cpu=1 mpidr=0x101 count=4 @SweetCPU.cpp:80
```

Before it, the log shows xnu getting a long way: device-tree platform
expert, AppleKeyStore, IOWatchdog, IOCoreSurfaceRoot, HID buttons, HID
touch -- all registered, all rendered on caprip's panel. `iBoot version:
topaz-shim`.

The guard that fired comes from patch `0078`, which allows only
`(phys_id & 0xff) == 0` -- fine for sweet's MPIDRs (0x000..0x700, Aff1 =
core), wrong for bengal, where Aff1 is the *cluster* and Aff0 the core, so
the Gold cluster is 0x100..0x103. Patch `0080` fixes exactly that.

**`0080` never applied.** The build log for the artifact in use
(`NoNameBuilder/ios-topaz` run 39498191206) shows **52 of 118 patches
skipped**, because `git apply` is all-or-nothing per patch file and one
stale hunk discards the rest:

```
Skipping patch .../0080-topaz-cpu-topology-skip-sweet-hw.patch
error: patch failed: bsd/dev/sweet_ufs.c:656
```

The `SweetCPU.cpp` hunk in that same patch matches the tree exactly -- it
was simply collateral. Independent confirmation: the shipped binary still
contains the string `Kryo 470`, which `0080` renames to `Kryo 260`.

Fix: split the patch so the hunk that matters stands alone.

| patch | touches | expected |
|---|---|---|
| `0080` | `SweetCPU.cpp` | **must apply** -- the topology guard |
| `0080b` | `sweet_ufs.c` | still skipped; only gates keys/touch/USB behind `sweethw=1` |
| `0080c` | `SWEET.h` | a comment |

### The other 51

Also skipped: `0061` (the iPhone-X display-size patch -- so the panel is
*not* in fact being presented as 1125x2436 in this build; the framebuffer
works because `boot_args.Video` drives `AppleCLCD` directly), all touch,
all USB, display power, backlight, and the whole `SweetSurface` series.
None of them block reaching userspace, so they are follow-up work rather
than a prerequisite. Anyone rebuilding should re-read the apply log before
trusting a patch is in: `gh run view <id> --log | grep -i 'skipping patch'`.

## Userspace reached (2026-11-06)

```
*** SWEET userspace: init running as PID 1 ***
SWEET init: still alive
SWEET init: still alive          <- every 5 s, on caprip's panel
```

Darwin userspace runs on the Moto G30. The repeating line is the whole
proof: it is `tools/sweet-init.S` calling `select(NULL, 5s)` in a loop and
writing to `/dev/console`, so exec, the user/kernel boundary, devfs, the
syscall path (`write`, `getpid`, `select`) and the scheduler all work, and
PID 1 is alive rather than exiting (which would panic the kernel).

No filesystem is involved. xnu's **mockfs** serves a bare Mach-O memory
disk as `/sbin/launchd`, so the "root" is simply the 16,635-byte static
ad-hoc-signed binary from `tools/mkinit.py`, handed to `mkpayload.py
--ramdisk` and booted with `rd=md0`. `mkpayload` appends it as a segment
and adds `/chosen/memory-map RAMDisk = <0xc2120000, 0x8000>` for
`IOFindBSDRoot`. The HFS+ work is for the *real* root, not for this.

### Getting there without a Mac

The proper fix is the split patch `0080` committed here, but it could not
be built: **no macOS runner can be acquired for this account.** Every
attempt, on every surviving label:

| label | annotation |
|---|---|
| `macos-14` | `The configuration 'macos-14-arm64-us-default' is not supported` |
| `macos-15` | `The job was not acquired by Runner of type hosted even after multiple attempts` |
| `macos-15-intel` | same |
| `macos-latest` | same, plus a macOS-arm64 capacity notice |

So patch 0080's semantics were applied straight to the built kernel
instead, by `tools/caprip/binpatch-cpu-topology.sh`. The kernel has no
`LC_CODE_SIGNATURE` and no chained fixups, so editing code bytes is safe.
Three instructions, all in place and same-length:

```
fffffe0007aba288  711c011f -> 7108011f   cmp w8, #0x700  ->  cmp w8, #0x200
fffffe0007aba28c  54000c88 -> 54000c82   b.hi            ->  b.cs
fffffe0007aba290  12001d08 -> 121e1508   and w8,w8,#0xff ->  and w8,w8,#0xfc
```

The first pair gives `(phys_id >> 8) > 1`; the third gives
`(phys_id & 0xff) > 3`, because 0..3 have no bits above bit 1, so masking
with `0xfc` *is* "greater than 3" for a byte. Together that is exactly
patch 0080's guard. Checked against caprip's real MPIDRs: `0x100..0x103`
all pass, `0x104` would still be rejected. The script verifies the current
word at each address before writing and refuses on any mismatch.

This is a stopgap. `0080` is committed and will apply whenever a macOS
runner can be had; the binary patch then becomes unnecessary.

### Rebuilding this exact image

```sh
tools/caprip/make-init.sh                      # -> build/init/launchd
tools/caprip/binpatch-cpu-topology.sh          # -> kernel.development.caprip
tools/build_caprip.sh kernel.development.caprip build/init/launchd
fastboot boot out/xnu-caprip.img
```

## Known gaps

- `/product` node absent: upstream's `research/ipsw-x/d22ap.adt` is not in the
  repo, so MobileGestalt data is missing. Irrelevant to the console milestone.
- Touch (`sweettouch=0`) -- `SweetHID` still hardcodes 1080x2400 for its
  digitizer scaling; needs the same treatment `0061` gave the framebuffer.
- **No eMMC/SDHCI root driver exists in any port.** This is the long pole for a
  real iOS root; the interim path is a minimal HFS+ ramdisk for `rd=md0`.
