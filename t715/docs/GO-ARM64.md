# Passing a Galaxy Tab S2 (SM-T715) to arm64 Omarchy: the two routes

The Samsung Galaxy Tab S2 8.0 LTE (SM-T715) has an Exynos 5433, a 64-bit SoC that Samsung's
signed bootloader only starts in 32 bits. Two repositories let it run a 64-bit system:

| Brick | Where | What it holds |
|---|---|---|
| **The boot** | this fork, [elkir0/bnuuyloader](https://github.com/elkir0/bnuuyloader) | the loader that makes the tablet start an arm64 kernel at every boot, with the boot screen; the kernel patches; the rescue; the tools |
| **The system** | [omarchy-tab-s2](https://github.com/elkir0/omarchy-tab-s2) (its page on the 64-bit port: [docs/ARM64.md](https://github.com/elkir0/omarchy-tab-s2/blob/main/docs/ARM64.md)) and `rootfs/` here | Omarchy for the tablet: its 32-bit release today; the recipes of the arm64 image (`rootfs/`, [ROOTFS-AARCH64.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROOTFS-AARCH64.md)) |

There are two ways to use them, and this page is the door to both.

- **Route 1, "I download, I flash, it boots."** For whoever wants arm64 and nothing else. It is
  the owner's goal. **On 2026-11-25 it is not open yet**: section 1 says exactly where it stands.
- **Route 2, the long one.** For whoever wants to do it today, and understand. Section 2 is the
  map; each step links to the page that tells it.

Three pages this one points to, and what builds the image (`t715/rootfs/`,
`t715/kernel/config/`, `t715/build-arm64.sh`), are in the fork's `main` only: their links go
there.

All of it was made and tried on **one tablet**: bootloader `T715XXU2CRH1`, hardware revision 9.
Since 2026-11-25 that tablet boots Omarchy 4.5 on arm64 by itself at every power-on, with the
owner's picture as its boot screen; its 32-bit root is gone, and BOOT and RECOVERY hold the
rescue.

## Before either route

- **Own device only.** This is a bootloader exploit. It writes the PARAM partition, which the
  32-bit port's rules tell never to write: the owner made that exception for the loader, on
  2026-11-24 ([../README.md](../README.md), section 11).
- **The Knox warranty bit is blown for good**, by anything that runs here: as with the 32-bit
  port. There is no way back from that.
- **Read "Read this first" of the 32-bit port's guide** (`docs/INSTALL.md` in omarchy-tab-s2):
  its warnings hold here too. Do not rely on this tablet for an emergency call.
- **Back up EFS before anything else**, as that guide says. No tool can rebuild it.
- **Know how to get out.** With a loader in PARAM, the way back is the rescue
  ([RESCUE.md](RESCUE.md)) and, past it, download mode with your own stock PARAM image. Section 2
  keeps a way back at every step: follow its order.

## 1. Route 1: "I download, I flash, it boots"

**Not open on 2026-11-25.** There is no file to download that turns a stock, or 32-bit, tablet
into an arm64 one. Nothing in this section can be done today: it is here to say what the short
route will be, and what it still lacks.

### 1.1 What it will be

| Step | What you will do |
|---|---|
| 1 | Download two files from a release of omarchy-tab-s2: the arm64 Omarchy image for the Tab S2, and the installer image. Check the checksums |
| 2 | Flash the installer to BOOT and RECOVERY in download mode, with Odin or Heimdall, as the 32-bit port's guide does; put the image on the tablet |
| 3 | Start the tablet. The installer does the rest by itself and restarts into Omarchy |

No computer after step 2, no command to type, nothing to build.

### 1.2 Why there has to be an installer

The loader cannot be shipped as a file. It lives in PARAM, and a PARAM image is Samsung's
firmware holding data of one tablet: no PARAM image can be distributed, and the forged logo must
be built from each tablet's **own** stock PARAM. The addresses it depends on are one
bootloader's, `T715XXU2CRH1`. So an installer has to run on the tablet, build the forged logo
from that tablet's own PARAM there, and write it. That installer is the main piece missing.

### 1.3 What is ready, what is missing

| Piece | State on 2026-11-25 |
|---|---|
| The loader, with the boot screen | **done**, on the owner's tablet at every boot since that day ([SPLASH.md](SPLASH.md)) |
| The rescue in BOOT and RECOVERY | **done**, on the owner's tablet; tried ([RESCUE.md](RESCUE.md)) |
| The arm64 kernel and its patches | **done**: Linux 6.12.114, eight cores ([KERNEL-CONFIG.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/KERNEL-CONFIG.md)) |
| The arm64 Omarchy image | **built from the sources** on the owner's computer; Omarchy 4.5 is the owner's daily system. **Not released** as a file to download |
| The installer image, for BOOT and RECOVERY | **not written**: it would do on the tablet what section 2 has you do from a computer |
| A forge of the loader on the tablet | **not written**: the loader is built on a computer today |
| Another tablet, another firmware | **not tried** |

This is Milestone 5 of [ROADMAP.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROADMAP.md). Until it is done, route 1 is closed.

### 1.4 What you can do today with no tooling

Install the 32-bit Omarchy: it is the turnkey release of omarchy-tab-s2 (1.0.5), and
[its guide](https://github.com/elkir0/omarchy-tab-s2/blob/main/docs/INSTALL.md) takes a stock
tablet there with Odin or Heimdall. Nothing of it has to be undone to take route 2
afterwards: route 2 starts from it.

## 2. Route 2: the long one, for power users

This is today's route. What it takes: the tablet running the 32-bit Omarchy, a computer with
Docker (everything here was done on macOS on Apple silicon, and the scripts assume it: about
20 GB free), the USB cable, and the readiness to recover a tablet from download mode if the
worst happens. A build takes from a few minutes to three quarters of an hour; the first arm64
boot is the moment to stay at the tablet.

The order below keeps a way back at every step. Do not skip ahead to the loader.

### 2.1 The map

| # | Step | Told in |
|---|---|---|
| 1 | Install the 32-bit Omarchy 1.0.5; reach the tablet over the USB link | omarchy-tab-s2: [its install guide](https://github.com/elkir0/omarchy-tab-s2/blob/main/docs/INSTALL.md) |
| 2 | Read the two dumps of **your** tablet; keep the PARAM copy safe | [../README.md](../README.md), section 3 |
| 3 | Build the loader's tools; calibrate; build the loader | [../README.md](../README.md), section 4; [SPLASH.md](SPLASH.md), section 9 |
| 4 | Build the arm64 kernel and the Omarchy image | [KERNEL-CONFIG.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/KERNEL-CONFIG.md); [ROOTFS-AARCH64.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROOTFS-AARCH64.md) |
| 5 | CACHE: back it up, shrink it, write a kernel to a slot | [../README.md](../README.md), section 6 |
| 6 | USERDATA: the arm64 root image and its modules | [ROOTFS-AARCH64.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROOTFS-AARCH64.md), section 9 |
| 7 | The loader into PARAM: the tablet boots arm64 | [../README.md](../README.md), section 6 |
| 8 | The rescue into BOOT, then RECOVERY | [RESCUE.md](RESCUE.md), sections 4 and 5 |
| 9 | Only now, if room is wanted: the 32-bit root may go | [RESCUE.md](RESCUE.md) |

### 2.2 The steps, in a few words each

**1. The 32-bit system.** It is what you read the dumps from, and what BOOT boots whenever the
loader does not start arm64: the way back of every step until the rescue is in place. The port's
`device/tssh` is ssh, as root, to the tablet over the USB cable (172.16.42.1).

**2. The two dumps.** As root on the tablet's Linux, before anything else:

```bash
dd if=/dev/mmcblk0boot0 of=/run/t715/userdata/media/0/mmcblk0boot0.bin bs=1M count=4
dd if=/dev/mmcblk0p8     of=/run/t715/userdata/media/0/PARAM-mmcblk0p8.bin bs=1M count=8
```

Copy both to the computer into `t715/loader/dumps/`, and keep the PARAM copy somewhere safe as
well: it is the stock image you would flash in download mode. They are Samsung's firmware and
yours alone: never commit them, never share them.

**3. The loader.** The Python environment, the calibration of the forged block against S-Boot's
own decoder, then the loader itself, with `--verify`: one command decodes the logo with that
decoder and refuses the image unless it leaves exactly the bytes the exploit needs. With the
owner's boot screen:

```
venv/bin/python -I scripts/build_kboot.py --prod --geometry wide --art art/splash-bnuuy-and-me.png --luma-floor 4 --chroma-floor 3 --name kboot7 --verify
```

Without it, the black logo: `--prod --name kboot6`. Or with your own picture
([SPLASH.md](SPLASH.md), section 9).

**4. The kernel and the image.** `t715/build-arm64.sh` builds the kernel in a container; the
image with `bash build.sh` in `t715/rootfs/`. Build the image with your ssh key, or nobody can
log in to the arm64 system. **Mind the kernel's boot arguments.** They live in its device tree.
Those of daily use (`t715/kernel/config/bootargs-daily.dts`) name the root
`USERDATA/omarchy-arm64`. The others are for tests: they make the kernel go back to BOOT after a
while, skip the mark, and open a root shell over the USB cable, and the build applies one of
them by default. Read "The build" in [KERNEL-CONFIG.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/KERNEL-CONFIG.md), section 4, and
[../kernel/README.md](../kernel/README.md), before the first boot.

**5 and 6, then 7.** The installer does the writing, from the computer, with the tablet up under
either system:

```bash
cd t715/loader
export ORIG_SHA=$(shasum -a 256 dumps/PARAM-mmcblk0p8.bin | cut -c1-64)
T=../tools/t715-arm64-install
# The tools reach the tablet through omarchy-tab-s2's device/tssh, looked for next to the fork.
# If it is elsewhere: export T715_TSSH=/path/to/omarchy-tab-s2/device/tssh

venv/bin/python -I scripts/slot.py backup CACHE-before.bin   # the whole partition, the way back for it
venv/bin/python -I scripts/slot.py shrink
$T kernel Image DTB                                         # the kernel, and its device tree with the daily boot arguments
$T rootfs omarchy-arm64 ../rootfs/out/rootfs-aarch64-omarchy45.img   # the root: USERDATA/omarchy-arm64
$T modules omarchy-arm64 modules.tar.xz
$T loader out/kboot7.param                                  # from here, every boot runs the loader
$T status
```

`Image`, `DTB` and `modules.tar.xz` are what `build-arm64.sh` wrote (its `kernel-out/`).

Before the first arm64 boot, read the check list "Before the first boot on the tablet" in
[ROOTFS-AARCH64.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROOTFS-AARCH64.md), section 9.

**8. The rescue.** It is in omarchy-tab-s2's tree since 2026-11-25. Built from it with the
loader you installed, written to BOOT while the loader works, then to RECOVERY. From this point a loader that fails to fire costs one
restart, not the tablet ([RESCUE.md](RESCUE.md)). The rescue replaces the 32-bit system's own
boot image in BOOT and RECOVERY: keep the release's `boot.img` and `recovery.img` at hand, to put
them back if ever wanted.

**9. The 32-bit root.** `USERDATA/omarchy` can then be deleted, if you want its room. The
installer's `unloader` refuses to put the stock PARAM back while it is gone, unless you insist
(`--no-32bit-root-ok`): with the stock image in PARAM, BOOT is what boots.

### 2.3 What you get, and what you do not

**What works**, on the one tablet tried: Omarchy 4.5 on arm64 as a daily system, user space in
about 13 s, a soak of three hours with eight busy cores; the boot screen of your choice; display,
touch, GPU, Wi-Fi, Bluetooth, sound, sensors, battery, the microSD card and the LTE modem's
processor as far as the health check sees. The details: [../README.md](../README.md), section 1,
and [ROADMAP.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROADMAP.md).

**What does not yet**: suspend to RAM, the A57 cores above 1.2 GHz, Android apps, hot-unplug
([ROADMAP.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROADMAP.md), Milestone 4); the modem with a SIM; the camera's user space. One red
pixel on the boot screen, below the picture ([SPLASH.md](SPLASH.md), section 6). And everything
is one tablet's: another unit, another firmware, and the whole method has to be made again.

### 2.4 When it does not come up

| What you see | What it means | What to do |
|---|---|---|
| The arm64 desktop comes up, but the next boot shows the boot screen, then the rescue's message, twice, then arm64 again | the arm64 system did not mark itself up: the loader's ledger hands two boots to BOOT, then tries again | the arm64 system is up, so `$T status` works over ssh: look at what failed to start (`systemctl --failed`) and fix it. A boot that comes up and marks itself makes the next one try as usual |
| The boot screen, then the rescue's message, twice, then the boot screen again, and never arm64 | the kernel or the root does not start | the loader keeps trying, every third boot. To get in: the rescue's root shell over the USB cable, at each rescue boot ([RESCUE.md](RESCUE.md), section 7). While a system answers ssh, `$T` can write a kernel and a tree known to work (`$T kernel Image DTB`, `$T rootfs omarchy-arm64 IMAGE --replace`), or `$T unloader`. To start over cleanly: download mode, your stock PARAM back with Heimdall or Odin, then the 32-bit port's release as its guide says. To know why it fails: the ring and pstore ([../README.md](../README.md), section 8) |
| The rescue says PARAM does not hold the loader known to work, writes it back, restarts | a loader the rescue was not told of is in PARAM | nothing to do: it is the rescue working. Tell it about the new loader at the next build (`--paramrescue-also`) |
| The stock system boots at every start | PARAM holds the stock image | `$T status` to confirm; `$T loader out/kboot7.param` to start arm64 again |
| You want BOOT's system back for good | | `$T unloader` (it needs the 32-bit root, or `--no-32bit-root-ok` when the rescue is in BOOT) |
| Nothing answers, and the screen never shows the boot screen | the loader hangs before it can hand back: not the one for this bootloader, or a wrong logo | download mode, and flash your stock PARAM back with Heimdall or Odin |

The last line is the one the rescue exists to make rare, and the one route 1 exists to remove.
