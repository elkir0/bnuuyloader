<p align="center"><img src="https://github.com/meowybnuuy/bnuuyloader/blob/main/bnuuy.gif?raw=true" width="128" height="128"></p>
<h1 align="center">bnuuyloader for the Galaxy Tab S2</h1>

<p align="center"><strong>Run 64-bit Linux on the Samsung Galaxy Tab S2 8.0 LTE (SM-T715).</strong><br>
The complete adaptation of <a href="https://github.com/meowybnuuy/bnuuyloader">bnuuyloader</a> to one tablet.</p>

The Galaxy Tab S2 has an Exynos 5433: a 64-bit SoC that Samsung's signed bootloader only starts in
32 bits. [bnuuyloader](https://github.com/meowybnuuy/bnuuyloader), by **bnuuy**, found the way in,
on a Galaxy Note 4: a vulnerability in the boot logo, CVE-2026-21155, lets code run inside the
bootloader, early enough to switch the SoC to 64 bits and start a kernel of one's own.

**This fork is that idea, made into a complete port for the Galaxy Tab S2.** It gathers what the
adaptation produced since it began, on 2026-11-23: a loader that boots a 64-bit kernel at every
power-on, a boot screen of the owner's choosing, a rescue that brings a lost loader back by itself,
the kernel's patches, the tools, and the write-up of all that was found on the way. Since
2026-11-25, one tablet boots Omarchy 4.5 in 64 bits by itself at every power-on.

It is not affiliated with bnuuy, with Samsung, or with Omarchy.

<p align="center"><img src="t715/loader/art/splash-preview.png" width="230" alt="The boot screen: a white rabbit and a pale butterfly, centred on a black background"></p>

*The boot screen. The tablet's own bootloader draws it before any kernel runs: the forged boot
logo covers the whole panel. The picture is the owner's.*

## What this fork is

| | |
|---|---|
| **A port of bnuuyloader to one tablet** | the Galaxy Tab S2 8.0 LTE (SM-T715), bootloader `T715XXU2CRH1`. The entry through the boot logo was rebuilt for this tablet's bootloader; everything after it was written for the tablet. |
| **A loader for every boot** | it lives in the PARAM partition. It starts a 64-bit kernel from a slot of the CACHE partition, checks what it starts, and hands back to the tablet's own bootloader whenever it has nothing to start. |
| **A boot screen** | the forged logo is the first thing the tablet shows. |
| **A way back** | a failed attempt costs the next two boots; a lost loader is put back by the rescue, by itself. |
| **A whole port, told** | the loader, the kernel, the tools, and eleven documents on what was measured, what broke, how it was fixed, and how to do it again. |
| **A turnkey install** | since omarchy-tab-s2 2.0.0, and in its current release, 2.1.0: an installer flashed once builds the loader on the tablet from its own PARAM ([t715/docs/GO-ARM64.md](t715/docs/GO-ARM64.md), section 1). One tablet tried; another firmware is refused. |

None of it would exist without bnuuy's work. The idea of entering through the boot logo, the
principle of the entry, and the monitor call that makes 64 bits possible are bnuuyloader's:
[How this fork goes beyond upstream](#how-this-fork-goes-beyond-upstream) says what was kept and
what was added, and [CREDITS.md](CREDITS.md) who made what.

## What you get

| Part | What it does | Where |
|---|---|---|
| **The loader** | runs inside the bootloader at every boot, reads a kernel through the bootloader's own storage reader, checks its hashes, and starts it in 64 bits, with the eight cores | `t715/loader/`; [t715/README.md](t715/README.md) |
| **The boot screen** | a picture on the whole panel, drawn by the bootloader itself, and the tool that makes a logo from any picture | `t715/loader/art/`; [t715/docs/SPLASH.md](t715/docs/SPLASH.md) |
| **The rescue** | a small system for BOOT and RECOVERY that puts the loader known to work back when PARAM holds none | `t715/rescue/`; [t715/docs/RESCUE.md](t715/docs/RESCUE.md) |
| **The kernel, in 64 bits** | ten patches on Linux 6.12.114: time without the stopped counter, the eight cores without PSCI, the board, hot-unplug and suspend to RAM; the daily kernel's configuration and its build | `t715/kernel/`; `t715/build-arm64.sh` |
| **The Omarchy image** | not here: it is the system brick, in [omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2), under [arm64/](https://github.com/elkir0/omarchy-tab-s2/tree/main/arm64): its build, its packages, the health check of a running tablet, and [everything about the image](https://github.com/elkir0/omarchy-tab-s2/blob/main/arm64/docs/ROOTFS.md). This fork carried a first copy of its recipes in release 0.9.0 | [omarchy-tab-s2's arm64/](https://github.com/elkir0/omarchy-tab-s2/tree/main/arm64) |
| **The tools** | the installer (the kernel's slots, the root, the loader), the test cycle job, the readers of the bootloader's log | `t715/tools/`; `t715/loader/scripts/` |
| **The documentation** | the findings, with addresses and register values; the loader cycle by cycle; the eight cores; the kernel configuration; the roadmap | `t715/docs/` |
| **A guide in two routes** | the short one (download, flash, boot) and the long one for power users, in order, with a way back at every step | [t715/docs/GO-ARM64.md](t715/docs/GO-ARM64.md) |

## What works today

State on 2026-11-26. Tested on one tablet: bootloader `T715XXU2CRH1`, hardware revision 9.

| What | State |
|---|---|
| ARM32 code inside S-Boot, from a forged boot logo | works, and hands control back to S-Boot |
| AArch64 at EL2, through the same monitor call as upstream | works, on the boot core and on the others |
| The production loader, in PARAM for good | `kboot7`: runs at every boot of the tablet since 2026-11-25 |
| The boot screen: S-Boot's own logo carrying a picture on the whole panel | works since 2026-11-25 ([t715/docs/SPLASH.md](t715/docs/SPLASH.md)) |
| Linux 6.12.114 arm64, read from a slot of the CACHE partition, hashed, started at EL1 | works, with its eight cores |
| Omarchy 4.5 on arm64 as the tablet's daily system | user space in about 13 s; a soak of three hours with eight busy cores |
| Suspend to RAM and hot-unplug on arm64, without PSCI | since 2026-11-26, the kernel of omarchy-tab-s2 2.1.0: five real sleeps out of five, with the modem and the Wi-Fi chip powered down first ([t715/kernel/README.md](t715/kernel/README.md)) |
| The way back after a failed attempt | seen on the tablet: the loader hands the next two boots to the rescue in BOOT, then arm64 is tried again |
| The rescue ([t715/docs/RESCUE.md](t715/docs/RESCUE.md)) | in BOOT and RECOVERY; seen once putting a lost loader back by itself: arm64 again 35 s after the restart |
| A turnkey install (download, flash, it installs) | omarchy-tab-s2 2.1.0's installer (since 2.0.0): [t715/docs/GO-ARM64.md](t715/docs/GO-ARM64.md), section 1 |
| Another unit, another firmware | not tried |

What was found about this tablet's S-Boot and about arm64 Linux on it is written up in
[`t715/docs/FINDINGS.md`](t715/docs/FINDINGS.md). How the loader works and how to work with it:
[`t715/README.md`](t715/README.md). How to pass a tablet from the 32-bit system to arm64, in
order, with a way back at every step: [`t715/docs/GO-ARM64.md`](t715/docs/GO-ARM64.md).

## Two ways to use it

- **The short route: download, flash, it installs.** [omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2)'s
  release 2.1.0 brings the arm64 image and an installer flashed once with Odin or Heimdall. The
  loader cannot be shipped as a file: it lives in PARAM, which is Samsung's firmware holding each
  tablet's own data, so the installer builds it on the tablet from the tablet's own PARAM, and
  checks it against the sha256 of this loader before writing it:
  [t715/docs/GO-ARM64.md](t715/docs/GO-ARM64.md), section 1.
- **The long route, for power users.** From the 32-bit system, with a computer and
  the USB cable: read the tablet's own dumps, build the loader, rehearse it, build the kernel and
  the image, and install in an order that keeps a way back at every step. The map is in
  [t715/docs/GO-ARM64.md](t715/docs/GO-ARM64.md), section 2; each step links to the page that
  tells it.

## What you must provide yourself

Two files of **your own** tablet, which no script of this repository makes and which must never be
committed or shared: they are Samsung's firmware, and the second also holds what S-Boot writes
there. They go in `t715/loader/dumps/`: see "What you need" in [`t715/README.md`](t715/README.md).

## Before you touch a tablet

**Own device only.** This is a bootloader exploit. It writes the PARAM partition. Know how to put a
stock PARAM back before you write one.

What can go wrong:

- **A bad image in PARAM** can leave the tablet in its bootloader. Three ways back, and the first
  must be in place before the others are needed: the rescue in BOOT
  ([t715/docs/RESCUE.md](t715/docs/RESCUE.md)), which puts the last loader known to work back by
  itself; the loader's installer, which puts a stock PARAM back (`t715-arm64-install unloader`);
  and a stock PARAM image flashed in download mode with Heimdall.
- **The warranty bit.** As in omarchy-tab-s2, anything that runs here blows the tablet's Knox
  warranty bit for good.
- **The bring-up arguments open a root shell.** `t715/kernel/config/bootargs-bringup.dts` turns on
  `t715.usbshell=1`: a root shell over telnet, with no password, on the USB cable. It is for
  bringing a system up, with a cable to one's own computer. The daily arguments do not have it:
  never leave it on.
- **Frequencies and voltages.** The Exynos 5433 has no safe generic table. On this tablet,
  mainline's OPP tables are below what its chip needs: by 25 mV on the A57 and 50 mV on the A53 at
  1200 MHz, by up to 75 mV lower down. Every chip has its own group. A driver that scales a clock
  without its supply, or a table that is not the chip's own, computes wrong: wrong hashes, crashes,
  then a hang, with no message. The loader changes no clock and no voltage. The kernel patches
  scale nothing beyond what the 32-bit port validated, on the chip's own tables.
- **The partitions never to write**, in the words of omarchy-tab-s2: RADIO, CDMA-RADIO, EFS,
  m9kefs1-3, BOOTLOADER, PARAM and BOTA. This port writes PARAM, where the loader's image lives,
  and CACHE, where the kernel's two slots live. The rule about PARAM is the owner's own exception,
  decided on 2026-11-24: the exploit is the case it did not cover.

## How this fork goes beyond upstream

bnuuyloader is a proof of concept for the Galaxy Note 4. This fork keeps its idea and its monitor
call; the loader was written again for the Galaxy Tab S2's bootloader, then grown into a port for
every day. On top of upstream's 24 files, the fork holds 529: about 67,000 lines, of which about
5,200 of documentation.

| | Upstream, the Note 4 | This fork, the Tab S2 |
|---|---|---|
| Entry | a forged heap node; the large-heap split writes over a saved return address | the same principle, rebuilt for this S-Boot: a forged heap head and a false free block |
| Finding the place in S-Boot | a byte signature, kept only with the Note 4's values | the same signature is in this S-Boot, once, with another heap base; the place was read in the code, with the tools in `t715/loader/scripts/` |
| The forged JPEG block | calibrated once, shipped in `assets/` | calibrated against S-Boot's own decoder, run in an emulator |
| After the monitor call | never returns to S-Boot | hands back to S-Boot whenever it can |
| At EL2 | a stack, then C | exceptions caught, MMU and caches on, then C |
| Storage | its own eMMC driver; an Android boot image | S-Boot's own reader; a raw kernel image and a device tree, hashed, in two slots of a partition |
| After a failed boot | a halt | the tablet's own kernel at the next boots |
| The other cores | "legacy SMC calls": they start in ARM32 and must be switched | an enable-method of the kernel's own: each core switches itself (the same monitor call) |
| Screen | 1440 x 2560 | 1536 x 2048; same framebuffer base, same display registers |
| Beyond the loader | | a boot screen, a rescue, ten kernel patches with the daily kernel's configuration, the recipes of an Omarchy image, the tools, twelve documents |

## Releases

The releases of this fork are pre-releases of the Tab S2 port. The first is
[0.9.0](https://github.com/elkir0/bnuuyloader/releases/tag/t715-0.9.0), the state of 2026-11-25;
[CHANGELOG.md](CHANGELOG.md) has what each one holds. A release is the sources of everything above,
at a state tried on the tablet. It holds nothing to flash: no PARAM image can be shared, and the
arm64 image comes with the system brick, [omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2).

## Layout

| Path | What | From |
|---|---|---|
| `build.py`, `compiler_util.py`, `payload_layout.py`, `sboot_util.py`, `requirements.txt`, `src/`, `assets/`, `bnuuy.gif` | the Note 4 loader | upstream |
| `t715/README.md` | the Tab S2 loader: how it works, how to work with it | this fork |
| `t715/loader/` | the loader's sources: `scripts/`, `stage2/`, `el1/`, `art/` (the owner's boot screen and its preview), and the ring reader `tools/seclog_dump/` | this fork |
| `t715/rescue/` | the rescue: in omarchy-tab-s2's `main` since 2026-11-25; here as a patch for a clone at 1.0.5, with its instructions | this fork |
| `t715/kernel/` | `patches/`: the ten kernel patches; `README.md`; `test-kernel/`: the first test kernel; `smp/`: the eight-core method as a patch series; `config/`: the daily kernel's configuration and build notes | this fork |
| `t715/docs/` | `GO-ARM64.md`, `SPLASH.md`, `RESCUE.md`, `FINDINGS.md`, `PRODUCTION-LOADER.md`, `SMP-DESIGN.md`, `SMP-EXPERIMENT.md`, `SMP-MONITOR.md`, `CPUFREQ-THERMAL.md`, `KERNEL-CONFIG.md`, `ROADMAP.md` | this fork |
| `t715/tools/`, `t715/build-arm64.sh` | the installer, the kernel build | this fork |
| the aarch64 Omarchy root image, the health check, their tests | in [omarchy-tab-s2's arm64/](https://github.com/elkir0/omarchy-tab-s2/tree/main/arm64) since 2026-11-25 (in `t715/rootfs/` here until then, release 0.9.0) | omarchy-tab-s2 |
| `CHANGELOG.md` | what each release of the fork holds | this fork |
| `CREDITS.md` | who did what, and the licences | this fork |
| `LICENSE` | MIT, Copyright (c) 2026 meowybnuuy | upstream |

## Upstream: bnuuyloader, by bnuuy

bnuuyloader is a proof of concept by meowybnuuy ("bnuuy"), for the Galaxy Note 4 (SM-N910C). It
abuses CVE-2026-21155, a vulnerability in the boot logo of Samsung's Exynos 5433 bootloader, to run
ARM64 code. Everything between the two marks below is bnuuy's README, word for word; only the
levels of its headings are lowered, so that it sits inside this section.

<!-- UPSTREAM-START -->
> [!NOTE]
> bnuuyloader is not intended for normal users yet, for now, it is intended for advanced users and developers. I've also only tested this on the Note 4 Exynos (N910C), you will probably have to make your own changes to make your device work, PRs are very much appreciated. \
> \
> The Note 4 with Qualcomm SoC **WILL NOT** work, as it's SoC is ARM32 entirely, while Exynos SoC is ARM64 (but limited to ARM32 in software).

<p align="center"><img src="https://github.com/meowybnuuy/bnuuyloader/blob/main/bnuuy.gif?raw=true" width="128" height="128"></p>
<h1 align="center">bnuuyloader</h1>

Bnuuys have invaded the Exynos 5433 SoC, allowing it to run ARM64 code!

### Why make this and how does it work?
I like the Note 4 Exynos (specifically N910C) quite a lot, in my opinion, it represents one of the last ever best Android phones released, due to all of the features it has. But, there is a problem preventing the SoC from aging very well, Samsung intentionally limited the SoC to ARM32 (ARMv7) in software, despite the SoC supporting ARM64.

This means that any OS is forced to use legacy ARM32 (ARMv7), which has been slowly phased out over time, making software compatibility worsen over time.

Making matters worse, the software which makes the SoC start in ARM32 is apart of the boot process, specifically S-Boot, which is signed by Samsung and therefore cannot be modified by anyone but Samsung.

However, thanks to [UnsignedChad's CVE-2026-21155](https://github.com/UnsignedChad/CVE-2026-21155-SVE-2026-3546), we can get code execution inside S-Boot, which runs in EL2, letting us run our own code early enough to switch the SoC back into ARM64 and implement our own tiny bootloader!

### Caveats
- Trusted Firmware-A does not exist, you will have to use legacy SMC calls to bring up the other cores, which means they will startup in ARM32 and you'll have to switch them to ARM64. This is very hacky, but it works. Also, the boot core is Cortex-A53.
- The bootloader is probably not very good, it was just enough to boot mainline Linux just enough in an Android boot image. My hope is that by getting this out, that it can be improved by others.
- Probably others I am forgetting...

### Building
To build a PARAM image (which contains bnuuyloader), you will need the `sboot.bin` and `param.bin` for your device (the S-Boot and PARAM must match the firmware on your device). You will also need LLVM/Clang to crosscompile the AArch32/AArch64 parts of bnuuyloader, as well as Python to run the build script.

You first need to install the dependencies `python3 -m pip install -r requirements.txt`, then you can run `python3 build.py --stock-param <path to original param> --sboot <path to original sboot>`. If everything goes right, it should build a `PARAM_bnuuyloader.tar`, which you can flash using Odin.

This has only been tested on the Note 4 Exynos, with firmware `N910CXXS2DRI2`, it may need adjusting for other firmwares, you may need to edit `payload_layout.py` if any issues occur.

Please bare in mind that bnuuyloader does not support booting AArch32 kernels, it is assumed that you are using bnuuyloader to only run AArch64 kernels, as that is the main point of bnuuyloader.

To boot an AArch64 kernel, you need to wrap it in an Android boot image (`boot.img`) and flash it to your device using Odin. However, you can also just change the boot image loading behavior to suit your needs better.

### LLM disclosure
Unfortunately, I must admit that LLM assistance was used in the making of bnuuyloader. If you are turned off by this, I am sorry. My intent *was/is* to get this out there so that perhaps more cleaner implementations could be done, it shouldn't be that painful. PRs are appreciated if you'd like to clean it up, although I feel as if this code is already pretty clean. In the middle of attempting to clean this project up, my Note 4 Exynos died.

My hope is that by disclosing this here that you will understand that I am trying to act in good faith by being honest about how it was used, I am not here to make arguments for or against LLM assistance.

I am not interested in being a shill for AI, if you are looking to promote this project on your AI-centric Twitter page or blog, please leave me alone, I am not interested in being a hypebeast.
<!-- UPSTREAM-END -->

## Credits and licence

- **[bnuuyloader](https://github.com/meowybnuuy/bnuuyloader), by bnuuy** (MIT): the idea of using
  the boot logo vulnerability to run 64-bit code on an Exynos 5433, the loader for the Galaxy
  Note 4, and the monitor call that makes it possible.
- **[UnsignedChad](https://github.com/UnsignedChad/CVE-2026-21155-SVE-2026-3546)**: the write-up
  and the proof of concept of CVE-2026-21155.
- **The Linux kernel developers**: the kernel that the patches of `t715/kernel/` are made of.
- **[Omarchy](https://omarchy.org)** and **[omarchy-mobile](https://github.com/derekross/omarchy-mobile)**,
  by Derek Ross: the desktop the image is built from.
- **[elkir0](https://github.com/elkir0)**: the port to the Galaxy Tab S2, and
  [omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2), the tablet's 32-bit Linux port that
  it builds on.

The port to the Tab S2 was made with AI coding agents, as bnuuy discloses for upstream. What is
taken from upstream, what is new, and the licence of every part: [CREDITS.md](CREDITS.md).
