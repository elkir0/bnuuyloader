# The kernel side of the arm64 port

What a Linux kernel needs to boot on the Galaxy Tab S2 8.0 (SM-T715) in 64 bits, started by the
loader of [../](../README.md).

The tree is the kernel tree of [omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2): Linux
v6.12.114 plus its patch series, on the branch of its 1.0.5 release. The nine patches of `patches/`
go on top of it, in their order, with `git am`. The kernel that runs on the tablet is
`6.12.114-00105-g96a2510ad486`: that tree with the nine patches, built with the configuration of
`config/` (in the fork).

## The patches

| Patch | What it does |
|---|---|
| `0001` | **arm64: exynos5433: MCT without the architected timer.** The ARM generic counter does not run on this boot path: `CNTFRQ_EL0` reads 0. arm64 Linux panics on that, and its delays count the counter. For a machine compatible with `samsung,exynos5433` there is no panic, and no calibration from the counter, when the rate is 0; `__delay()` counts loop iterations. The Exynos MCT keeps time. |
| `0002` | **arm64: exynos5433: start the secondary CPUs without PSCI.** The enable-method `samsung,exynos5433-el2`, under `CONFIG_ARM64_EXYNOS5433_SMP`. The entry is a twelve-word AArch32 stub whose only job is the monitor call the loader makes for the boot CPU, `SMC 0x82000400`, which switches the core to AArch64 at EL2. An AArch64 stub `eret`s to EL1, and a holding pen hands the core to `secondary_entry()` once its own MPIDR is there. The CPU side is the 32-bit kernel's sequence, register for register. |
| `0003` | **dt-bindings: arm: cpus: the enable-method `samsung,exynos5433-el2`.** |
| `0004` | **arm64: dts: exynos: gts28ltexx: the board for a 64-bit kernel.** The 64-bit board file includes the 32-bit one and gives the eight CPU nodes the enable-method. |
| `0005` | **arm64: exynos5433: fix the MPIDR check of the secondary CPUs.** A shift of 6 bits where the code meant affinity level 2 refused every A53 secondary. |
| `0006` | **arm64: topology: no warning without an architected timer.** These cores have no AMU, so nothing is lost when the timer's rate reads 0. |
| `0007` | **arm64: dts: exynos: gts28ltexx: the A57 at 1.2 GHz at most (stage 1).** The A57 levels above 1.2 GHz are left out of the board's table until stage 2 of the frequency plan has run on arm64. BUCK2 is capped at 1.0625 V, the A57 cooling states are renumbered. |
| `0008` | **arm64: dts: exynos: gts28ltexx: no System MMU for a 64-bit kernel.** On arm64 the kernel selects `OF_IOMMU`. With no System MMU driver built, DECON and three other masters waited for the deferred-probe timeout, 16.9 s into the boot: a black screen behind the bootloader's logo. The twelve System MMUs are disabled; DECON binds at 0.5 s. |
| `0009` | **misc: modem_v1: build on arm64.** The driver has no 32-bit-only code; a Kconfig dependency and a `sizeof(size_t) == 4` assertion kept it to ARM. |

Patches `0001` to `0003` and `0005` to `0006` are for any Exynos 5433 started this way. Patches
`0004`, `0007`, `0008` and `0009` change files that exist only in the tree of omarchy-tab-s2: the
board file of this tablet and the modem driver it imports.

The findings behind them are in [../docs/FINDINGS.md](../docs/FINDINGS.md), sections 13, 14, 17 and
19.

## What the kernel must be

| Need | Why |
|---|---|
| `CONFIG_CLKSRC_EXYNOS_MCT=y` | the time base: the architected timer does not run |
| `CONFIG_ARM64_EXYNOS5433_SMP=y` | the seven other cores |
| `CONFIG_SAMSUNG_SEC_LOG_CONSOLE=y` | `console=sec_log`: the kernel's log goes on in S-Boot's RAM log ring, where the loader's ledger reads `KBOOT: up`. Without that mark the ledger counts every boot as a failed try, and the tablet never boots arm64 twice in a row |
| `CONFIG_S3C2410_WATCHDOG=y` | the loader arms the watchdog; the kernel must neither stop it nor let it fire |
| The initramfs built in | the loader passes no initrd: the kernel's own initramfs mounts the root |
| `CONFIG_RANDOMIZE_BASE` not set | the kernel of this port is built without it: the loader starts the `Image` at a fixed address, 0x42000000. A kernel with it has not been tried |
| An uncompressed `Image`, with a text offset of 0 | a slot of CACHE holds it as it is: no compression, no decompressor in the loader |

## The boot arguments the loader depends on

The daily arguments of the tablet are in `config/bootargs-daily.dts` (in the fork). Four of them
matter to the loader:

| Argument | Why |
|---|---|
| `console=sec_log sec_log=0x200000@0x26000000` | the kernel's log goes on in the ring, so that `KBOOT: up` reaches the ledger |
| `s3c2410_wdt.tmr_atboot=1` | without it the driver stops, at probe, the watchdog the loader armed |
| `watchdog.handle_boot_enabled=1 watchdog.open_timeout=120` | the kernel's watchdog core feeds the watchdog the loader armed, for 120 s at most after boot, until a service of the system opens it |
| `quiet` | console loglevel 4: the boot mark, at level 3, still reaches the ring |

A test image, which resets by itself, uses `watchdog.handle_boot_enabled=0` instead: there the
kernel must not feed the watchdog at all.

## Building

In the fork: `../build-arm64.sh` builds the kernel in a container from a clone of that tree, with
`config/` and the boot argument overlays, and writes the `Image`, the modules and the device trees.
The test kernel of the first boots, with a static init that reads the tablet's state and restarts
it, is in `test-kernel/` (in the fork).

The loader checks what it is given: the arm64 magic of the `Image`, a text offset of 0, the
`image_size` of its header (the kernel's footprint in memory, `.bss` included), and the magic and
the `totalsize` of the device tree.

## State on 2026-11-25

**Proven on the tablet.** The nine patches, on Linux 6.12.114: one core first, then the eight cores
under load (2026-11-24), then the full kernel of the daily system, at every boot since 2026-11-25.

**Built or rehearsed only.** Nothing: every patch has run.

**Open.** Hot-unplug without PSCI on arm64: the kernel refuses to take a CPU offline. Suspend to
RAM: the 32-bit code is ARM32 machine code. The A57 above 1.2 GHz. Another kernel version.
