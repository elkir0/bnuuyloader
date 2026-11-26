# Changelog

Releases of the fork: the port of [bnuuyloader](https://github.com/meowybnuuy/bnuuyloader), by
bnuuy, to the Samsung Galaxy Tab S2 8.0 LTE (SM-T715). A release holds the sources, at a state
tried on the tablet. It holds nothing to flash: no PARAM image can be shared (it is Samsung's
firmware and one tablet's data), and the arm64 image comes with the system brick,
[omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2).

## Unreleased

- **The Omarchy image went to the system brick.** `t715/rootfs/`, the health check
  (`t715/tools/t715-arm64-health`), its tests (`t715/tests/`) and `ROOTFS-AARCH64.md` are in
  [omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2), under [arm64/](https://github.com/elkir0/omarchy-tab-s2/tree/main/arm64), where they are kept up to date (since this
  release: omarchy-mobile's head with the modem's interface, dictation rebuilt for the tablet's
  ARMv8.0 CPU, a first-run onboarding with the AI apps). This fork keeps the boot: the loader,
  the kernel, the rescue, the installer, the findings. The guide's links follow.
- **The short route is open: omarchy-tab-s2 2.0.0.** Its installer, flashed once to BOOT and
  RECOVERY, does on the tablet what route 2 does from a computer: it copies the arm64 image into
  USERDATA, writes the kernel's slot to CACHE, and builds this fork's loader `kboot7-cas3` from the
  tablet's own PARAM (the archive's `logo.jpg` replaced by the loader's), written only if its
  sha256 is the loader's. [t715/docs/GO-ARM64.md](t715/docs/GO-ARM64.md), section 1, tells how;
  the code is omarchy-tab-s2's `boot/initramfs/init` (`t715.golden`) and `boot/golden/`.
- **Suspend to RAM and hot-unplug on arm64: the kernel of omarchy-tab-s2 2.1.0 (2026-11-26).** A
  tenth patch, `0010`, with no PSCI: a core goes down through the secure monitor's shutdown call,
  made from AArch64; the tablet sleeps through the monitor's sleep call, with the 32-bit kernel's
  PMU and clock programming unchanged; on a wake-up a second AArch32 stub switches the boot CPU to
  AArch64 again and resumes the kernel. On the tablet: all seven secondaries down and back, four
  rounds; five real sleeps out of five, with the modem's processor and the Wi-Fi/Bluetooth chip
  powered down first. The kernel is `6.12.114-00106-gd30e37ad41ab`, with
  `CONFIG_ARM64_EXYNOS5433_SUSPEND`, and with `CONFIG_COMPAT` for Waydroid's arm64 Android image,
  which runs 32-bit services and apps; the daily arguments carry `exynos5433_sleep=dryrun`, and
  the root arms each sleep. (`t715/kernel/`, `t715/build-arm64.sh`;
  [t715/kernel/README.md](t715/kernel/README.md); [FINDINGS.md](t715/docs/FINDINGS.md), section 23)
- **The secure monitor, read.** [SMP-MONITOR.md](t715/docs/SMP-MONITOR.md) has its missing
  sections: how the monitor dispatches a call from AArch64, its `0x82000400`, shutdown and sleep
  handlers, how a core and the SoC come back after a power-down, harmless probe calls, and what
  must never be done (unplug the boot CPU, call `0x82000401`). Two readings of earlier pages are
  corrected: `HCR_EL2` = 2 at the EL2 entry is bit 1, not RW, and `CPTR_EL2` `0x33FF` traps
  nothing.

## 0.9.0, pre-release (2026-11-25)

The first release of the fork: what the adaptation produced since it began, on 2026-11-23, in one
place. A pre-release, because it was tried on one tablet only, there is no installer yet, and
another unit or another firmware was never tried.

On that tablet since 2026-11-25: it boots Omarchy 4.5 in 64 bits by itself at every power-on, user
space in about 13 s, with the eight cores; a soak of three hours with eight busy cores; the LTE
modem's processor online; a cold boot by the power key.

- **The loader (`kboot7`).** In PARAM for good. It runs inside the bootloader at every boot, from a
  forged boot logo; reads a kernel from a slot of the CACHE partition through the bootloader's own
  reader; starts it only if its hashes match; hands back to the bootloader whenever it has nothing
  to start. A ledger in the bootloader's log gives the tablet back after a failed attempt.
  (`t715/loader/`; [t715/README.md](t715/README.md);
  [PRODUCTION-LOADER.md](t715/docs/PRODUCTION-LOADER.md))
- **The boot screen.** The forged logo is as wide as the panel and carries a picture, drawn by the
  bootloader itself before any kernel. Huffman tables built for the file make room for it; the
  builder decodes the logo with the bootloader's own decoder and refuses a wrong one.
  ([SPLASH.md](t715/docs/SPLASH.md))
- **The kernel in 64 bits.** Nine patches on Linux 6.12.114: the MCT as the time base (the ARM
  counter does not run on this boot path), the eight cores started without PSCI, the board for a
  64-bit kernel. The daily kernel's configuration, translated from the 32-bit release's, and its
  build. (`t715/kernel/`, `t715/build-arm64.sh`, [KERNEL-CONFIG.md](t715/docs/KERNEL-CONFIG.md))
- **The Omarchy image.** The recipes that build an arm64 Omarchy 4.5 image for the tablet, as they
  stood at this release. (`t715/rootfs/`, [ROOTFS-AARCH64.md](t715/docs/ROOTFS-AARCH64.md))
- **The rescue.** A small system for BOOT and RECOVERY that puts the loader known to work back
  when PARAM holds none, and restarts. It is in omarchy-tab-s2's tree; here as a patch for a clone
  of its 1.0.5. Seen once healing the tablet by itself: back under arm64 35 s after the restart.
  (`t715/rescue/`, [RESCUE.md](t715/docs/RESCUE.md))
- **The tools.** The installer (the kernel's slots, the root, the loader), the health check, the
  test cycle job, the readers of the bootloader's log. (`t715/tools/`, `t715/loader/scripts/`)
- **The documentation.** Twelve documents: the findings about this tablet's bootloader and about
  64-bit Linux on it, with addresses and register values; the loader cycle by cycle, `kboot1` to
  `kboot7`; the boot screen; the rescue; the eight cores; cpufreq and thermal; the kernel
  configuration; the image; the roadmap; and the guide in two routes. ([t715/docs/](t715/docs/))

**How to use it.** [t715/docs/GO-ARM64.md](t715/docs/GO-ARM64.md). The short route (download,
flash, boot) is not open yet. The long route, for power users, works today, from the 32-bit
Omarchy of [omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2).

**What was verified.** From this tree, following the documented steps: the loader with the boot
screen, and the one with the black logo, rebuild byte for byte as the images tried on the tablet;
the 27 rehearsed situations of the loader pass 27 of 27, and the ledger against the tablet's own
decisions 6 of 6.

**Known limits.** One tablet, one bootloader (`T715XXU2CRH1`): another unit or another firmware
needs the whole method made again. No turnkey install. RECOVERY with the rescue's image was
written, never booted. One red pixel on the boot screen, below the picture. On arm64, not yet:
suspend to RAM, the A57 cores above 1.2 GHz and their hot-unplug, Android apps, the modem with a
SIM, the camera's user space.

**Before this release.** 2026-11-23: the first image after which the tablet came back by itself.
2026-11-24: the chain, piece by piece, up to the eight cores in 64 bits under load and the
production loader. 2026-11-25: the daily system, the boot screen, the rescue.
