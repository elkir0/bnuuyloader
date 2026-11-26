# The SM-T715 kernel configuration on arm64

Release 1.0.5 of the owner's kernel, translated from arm32 to arm64, built, with its device tree.
Kernel configuration study, 2026-11-24. **Nothing described here was run on the tablet.** The
state on 2026-11-26 is in the last section.

## Summary

- **The tree.** A clone of the release repository (`t715-release-1.0.5`, head `1595b1660`) on a
  new branch `t715-arm64`, with one commit more: the Exynos MCT as time base when the ARM counter
  does not run (`512804d49`, our patch, as `../kernel/patches/0001-…patch`). Nothing else
  was changed in the tree: the owner's drivers compile for arm64 as they are.
- **The configuration.** `make ARCH=arm64 olddefconfig` on the release configuration, plus **one
  line of ours**: `CONFIG_ARM64_VA_BITS_39=y`. Of the release's 1361 built-in and module options,
  1208 are kept exactly, 153 cannot exist on arm64, and arm64 adds 231 of its own. Every one
  of the 384 is listed with its reason in `../kernel/config/config-report.md`. `COMPILE_TEST` is
  not set.
- **The build.** `Image` 15,523,848 bytes (14.8 MiB), uncompressed, no debug information, one
  warning in the whole build. It fits a 64 MiB slot with 49 MiB to spare.
- **The device tree.** `gts28ltexx-base.dtb` is byte for byte the release's DTB. The overlay
  changes exactly one property, `/chosen/bootargs`.
- **Two things to know before booting.** The clone is on a case-insensitive disk,
  where 13 paths of the Linux tree cannot all exist: the build goes through a view of the clone
  (§2.3), and any other clone made on such a disk has the same trap. And with the
  modules installed, udev loads `cpufreq-dt` and `panfrost` by itself at boot (§7.2).

## 1. Where things are

| Path (from `t715/docs/`) | What |
|---|---|
| the kernel tree (a clone of omarchy-tab-s2's) | clone of the release repository, branch `t715-arm64` |
| `../build-arm64.sh` | one command: configuration, checks, report, kernel, modules, device trees |
| `../kernel/config/Image`, `Image.sha256`, `SHA256SUMS` | the kernel and its hashes |
| `../kernel/config/.config` | the final configuration |
| `../kernel/config/config-report.md` | the translation symbol by symbol (written by the script) |
| `../kernel/config/config-release-arm32` | the release configuration, frozen (sha256 `c4709f8a…`) |
| `../kernel/config/config-arm64.changes` | our lines (one) |
| `../kernel/config/config-arm64.gone`, `.new` | the 153 gone and the 231 new symbols, with a reason each |
| `../kernel/config/gts28ltexx-base.dtb` | the board dts as the release builds it |
| `../kernel/config/gts28ltexx-bootargs.dtb`, `bootargs-overlay.dts` | the same with the kernel's arguments |
| `../kernel/config/modules.tar.xz` | the 71 modules, `lib/modules/<release>/` |
| `../kernel/config/System.map`, `kernel.release`, `build.log`, `build-summary.txt` | for the records |
| `../kernel/patches/` | the commit as a patch |
| `../kernel/config/NOTES.txt` | what went wrong and how it was solved |

## 2. The tree

### 2.1 Clone

`git clone --branch t715-release-1.0.5 file:///…/linux-6.12`, then branch `t715-arm64`. The
owner's repository is shallow (one boundary, 97 commits after the tag `v6.12.114`), so the clone
is too: 284 MB. `git status` is empty and HEAD is `512804d4958166048e65a6b1c2a6f45ba57381ab`.

### 2.2 The one commit: time without the architected timer

Our patch, unmodified, under a subject that keeps its file name. Its reason, from the
patch's own comments: on this device the bootloader leaves the ARM system counter stopped
(`CNTFRQ_EL0` reads 0, `CNTPCT_EL0` never moves), and arm64 Linux is built around that counter.
Stock code panics in `time_init()` ("Unable to initialise architected timer") and `__delay()`
measures a counter that does not advance. The Exynos MCT runs, and its driver already registers
the clock source, the clock events and `sched_clock` (`exynos_mct.c:258`), so the patch lets the
kernel rely on it alone: on `samsung,exynos5433` only, and only when the timer has no rate, skip
the panic and leave `lpj_fine` at 0 so that `calibrate_delay()` measures `loops_per_jiffy` on the
jiffies; count loop iterations in `__delay()` meanwhile.

### 2.3 The case-insensitive disk

The owner's trees are on a case-sensitive volume (`diskutil`: `Case-sensitive APFS`).
This clone is on the default one, where **13 paths of the Linux tree cannot all exist**,
because each differs from another only by letter case:

| Directory | Paths that survive | Paths lost (their name now reads the survivor) |
|---|---|---|
| `net/netfilter/` | `xt_hl.c`, `xt_tcpmss.c`, `xt_dscp.c`, `xt_rateest.c` | `xt_HL.c`, `xt_TCPMSS.c`, `xt_DSCP.c`, `xt_RATEEST.c` |
| `include/uapi/linux/netfilter/` | `xt_connmark.h`, `xt_mark.h`, `xt_dscp.h`, `xt_rateest.h`, `xt_tcpmss.h` | `xt_CONNMARK.h`, `xt_MARK.h`, `xt_DSCP.h`, `xt_RATEEST.h`, `xt_TCPMSS.h` |
| `include/uapi/linux/netfilter_ipv4/`, `_ipv6/` | `ipt_ecn.h`, `ipt_ttl.h`, `ip6t_hl.h` | `ipt_ECN.h`, `ipt_TTL.h`, `ip6t_HL.h` |
| `tools/memory-model/litmus-tests/` | one of the two `Z6.0+pooncelock+…` files | the other |

The commit is intact; only the working tree is affected. Consequences, all met:

- **The release builds from these files.** `CONFIG_NETFILTER_XT_TARGET_TCPMSS=y` compiles
  `xt_TCPMSS.c`, which on disk was the *match* source; `xt_connmark.c` and `xt_mark.c` include
  both members of a colliding pair. A kernel built by bind-mounting such a clone is wrong or
  does not compile. Our minimal kernel never met it (no netfilter).
- **The 13 lost paths are marked `skip-worktree`** in this clone (a bit of its index only), so
  `git status` is empty and they can never be committed by accident. Do not edit them through
  this clone: the build takes them from the commit.
- **The build uses a view.** A file mounted over a missing name is not enough: the compiler
  finds headers by path, but `make` decides whether a source exists from the directory listing,
  and a mount is never listed ("No rule to make target 'net/netfilter/xt_TCPMSS.o'" was the
  first failure of the first full build). `../build-arm64.sh` now builds through a tree of symbolic
  links made in the container: every entry of the clone by a link, and each directory that holds
  a lost path as a real directory of links with the lost names added, pointing at the committed
  content. The script checks the 13 checksums before it builds. The built `vmlinux` holds
  `tcpmss_tg4`, `tcpmss_tg6`, `tcpmss_mangle_packet` (the TCPMSS target) and `hl_mt6` (the HL
  match), as the release intends.

## 3. The configuration

### 3.1 Method

1. The release configuration under `ARCH=arm64 olddefconfig` gives the "plain" translation: what
   arm64 alone keeps of it. 1370 built in, 69 modules.
2. Our lines (`../kernel/config/config-arm64.changes`, then
   `../kernel/config/config-arm64.local` if it exists) are applied, and `olddefconfig` runs
   again. Final: **1369 built in, 69 modules**, sha256 `ca1c3724…`.
3. The script checks the final configuration symbol by symbol: every option the release builds
   has the same value unless it is in the gone list; everything arm64 adds is in the new list;
   and the port's fixed points hold (page size, address sizes, `COMPILE_TEST` off, and `COMPAT`
   until 2.1.0, no debug information, no built-in initramfs, …). An unexplained difference stops
   the build. Since 2.1.0 a symbol of the gone list that our lines build again is accepted, and
   named in the build's log: `COMPAT` brings some of the release's back.
4. `config-report.md` is written from that: changed by us, gone, unchanged, new, values.

To find out why a symbol is missing, two independent means were used and must agree: the Kconfig
text of the arm64 tree (`depends on`, the condition of the prompt, the enclosing blocks), and the
kernel's own evaluator: for each of the 153 gone symbols, force it on top of the result, with
and without `COMPILE_TEST=y`, and let `olddefconfig` say whether it survives (with control
symbols that must and must not survive).

### 3.2 The 153 gone

- **86 are not defined for arm64 at all**: everything of `arch/arm/` (`ARM`, the `CPU_V7` family,
  `SOC_EXYNOS*`, `ARCH_EXYNOS3/4/5`, `EXYNOS_MCPM`, `EXYNOS_CPU_SUSPEND`, VFP/NEON, high memory,
  the flat memory model, the 32-bit Spectre hardening, `VMSPLIT_3G`, …).
- **67 are defined but not selected**: 47 are capability flags without a prompt that arm64 does
  not select; 3 say `depends on ARM` (`ARM_CCI400_PORT_CTRL`, `SEC_MODEM_V1`, `SND_ARM`); 17
  have their prompt only `if COMPILE_TEST` on arm64; and `CMDLINE_EXTEND` does not exist on arm64.

### 3.3 Decisions

**1. `CONFIG_ARM64_VA_BITS_39=y`, the only line of ours** (the owner's decision: 39 bits are
enough, the SoC's devices and RAM fit in 40). The arm64 default is 52 bits. With 4 KiB pages one
choice carries the rest, all computed by Kconfig and listed in the report:

| Symbol | arm64 alone | Final |
|---|---|---|
| `ARM64_VA_BITS_52` / `ARM64_VA_BITS_39` | y / n | n / y |
| `ARM64_PA_BITS_52` / `ARM64_PA_BITS_48` | y / n | n / y |
| `ARM64_LPA2` (52-bit physical addresses) | y | n |
| `ARM64_VA_BITS`, `ARM64_PA_BITS`, `PGTABLE_LEVELS` | 52, 52, 5 | 39, 48, 3 |
| `ARCH_MMAP_RND_BITS_MAX` | 33 | 24 (the value kept, 18, still fits; the release had 8) |

The Cortex-A57 and A53 are ARMv8.0: with the default they would run 48-bit addresses through
5 levels of tables; this gives 3.

**2. `COMPILE_TEST` is not set.** Exactly 17 symbols of the release become selectable with it,
and we set it only if needed. None is, by the tree's own evidence:

| Symbol | Why it is not needed on this board |
|---|---|
| `EXYNOS_REGULATOR_COUPLER` | registers its coupler only on `samsung,exynos5800` (`exynos-regulator-coupler.c`); the board is `samsung,exynos5433`. It has never acted here |
| `EXYNOS_ASV_ARM` | tables for product id `0xE5422000` (5422/5800) only; anything else gets "No ASV support for this SoC" (`exynos-asv.c`). The board's own `EXYNOS5433_ATLAS_ASV` and `EXYNOS5433_G3D_ABB` stay built in |
| `EXYNOS_PMU_ARM_DRIVERS` | PMU tables for 3250/4210/4212/4412/5250/5420; the `samsung,exynos5433-pmu` entry carries no data (`exynos-pmu.c:256`) |
| `EXYNOS_IRQ_COMBINER` | no combiner node and no user of one in the board tree |
| `SAMSUNG_MC`, `EXYNOS_SROM` | no SROM controller on the board tree |
| `CLKSRC_SAMSUNG_PWM` | the S3C/S5P timer; the board's one PWM node is the PWM peripheral (`pwm-samsung.c`) |
| `EXYNOS_{3250,4,5250,5260,5410,5420}_COMMON_CLK` | other SoCs' clock units; the release built them through the 32-bit set, the 5433's come from `EXYNOS_ARM64_COMMON_CLK`, which the release built too |
| `PINCTRL_EXYNOS_ARM` | the ARMv7 pinctrl driver, same compatibles as `PINCTRL_EXYNOS_ARM64`: two drivers for one node |
| `PL353_SMC`, `NET_VENDOR_CIRRUS`, `NET_VENDOR_FARADAY` | no such hardware; no device under those menus in the release |

And `COMPILE_TEST=y` is not harmless here: on its own it turns on 125 unrelated symbols (105
built in, 20 modules: 38 clock drivers of other SoCs, 20 hardware random drivers, 9 DWC3 glue
drivers, the Meson and Uniphier pinctrl drivers, …) and it turns `LOCALVERSION_AUTO` off.
Our list had "the regulator coupler and the ASV/ABB options" as needed: the ASV/ABB
options are built in; the coupler would do nothing.

**3. The kernel's command line.** Not changed, and it needs care. The release sets
`CONFIG_CMDLINE="console=tty0 … exynos5433_sleep=dryrun"` with `CMDLINE_EXTEND=y`: on arm32 these
arguments are appended to the bootloader's. On arm64 `CMDLINE_EXTEND` does not exist; the default
is `CMDLINE_FROM_BOOTLOADER`: the device tree's `bootargs` are used as they are, and the built-in
string is used only when the tree carries none. So the overlay's `bootargs` are the whole command
line (no `console=tty0` added), and a tree without `bootargs` would start with the arm32 string,
which has no RAM log console.

**4. `COMPAT` off**, as decided (the result says so explicitly). Consequence: no 32-bit userland.
The release's 3 GiB/1 GiB split that lets 32-bit Android run in Waydroid is 32-bit only; on
arm64 only a 64-bit Android image could run.

Reversed on 2026-11-26, for omarchy-tab-s2 2.1.0: `CONFIG_COMPAT=y` in
`../kernel/config/config-arm64.local`. Waydroid's arm64 Android image is not 64-bit only: it runs
32-bit services (`boringssl_self_test32`, `zygote64_32`) and 32-bit apps.

**5. Left at the arm64 default**, as decided: 4 KiB pages; `SMP` (`def_bool y`, `nosmp` on the
command line). `NR_CPUS=8`, `HZ=250`, `PANIC_TIMEOUT=5` and `INITRAMFS_SOURCE=""` come from the
release unchanged.

**6. What arm64 adds (231 symbols)** is taken at its default; none is a decision of ours. 148
are capability flags without a prompt. The 83 with a prompt are errata of other CPUs (matched
per CPU at run time; 7 are for this SoC's A57 and A53), CPU extensions the v8.0 cores do not
implement, and a few real switches: `RELOCATABLE`, `RELR`, `UNMAP_KERNEL_AT_EL0`,
`MITIGATE_SPECTRE_BRANCH_HISTORY` (the counterpart of the release's `HARDEN_BRANCH_HISTORY`),
`RODATA_FULL_DEFAULT_ENABLED`, `FRAME_POINTER`, `KERNEL_MODE_NEON` (the release had it off: the
kernel may now use the NEON registers for crypto), `IOMMU_DEFAULT_DMA_STRICT`, and three new
drivers that make no firmware call here (§7.3). All 231 are in the report's table 4.

**7. One item of our list is not in the release: `EXYNOS_IOMMU`.** The release
configuration says `# CONFIG_EXYNOS_IOMMU is not set`, so the translated one does too. If the
IOMMU is wanted on arm64, it is a line in `config-arm64.local`; that is a new feature, not a
translation.

### 3.4 The hardware of the tablet

Every option below is built exactly as in the release (`y/y`, `m/m`). They are unchanged by
construction (anything not in the gone list keeps its value), and each was looked up.

| Function | Options (as in the release) |
|---|---|
| SoC, clocks | `ARCH_EXYNOS`, `COMMON_CLK_SAMSUNG`, `EXYNOS_ARM64_COMMON_CLK`, `EXYNOS_AUDSS_CLK_CON`, `EXYNOS_CLKOUT` (y); `COMMON_CLK_S2MPS11` (y) |
| Pinctrl, PMU, power domains | `PINCTRL_EXYNOS_ARM64`, `EXYNOS_PMU`, `EXYNOS_PM_DOMAINS` (y); the ARMv7 pinctrl is gone |
| Chip ID, the owner's bias drivers | `EXYNOS_CHIPID`, `EXYNOS5433_ATLAS_ASV`, `EXYNOS5433_G3D_ABB` (y) |
| Timers, interrupts | `CLKSRC_EXYNOS_MCT`, `ARM_ARCH_TIMER`, `ARM_GIC` (y) |
| Thermal, watchdog, reset | `EXYNOS_THERMAL`, `THERMAL_OF`, `S3C2410_WATCHDOG`, `WATCHDOG_HANDLE_BOOT_ENABLED`, `POWER_RESET_SYSCON`, `POWER_RESET_SYSCON_POWEROFF` (y) |
| PMIC, regulators, RTC | `MFD_SEC_CORE`, `REGULATOR_S2MPS11`, `RTC_DRV_S5M` (y) |
| Battery, charger | `POWER_SUPPLY`, `BATTERY_SM5703`, `CHARGER_SM5703`, `EXTCON_SM5502` (y) |
| eMMC, microSD | `MMC_DW`, `MMC_DW_EXYNOS`, `MMC_DW_PLTFM` (y) |
| Display | `DRM_EXYNOS`, `DRM_EXYNOS5433_DECON`, `DRM_EXYNOS_DSI`, `DRM_EXYNOS_MIC`, `DRM_SAMSUNG_DSIM`, `DRM_PANEL_SAMSUNG_S6E3HA2_TABS2`, `FRAMEBUFFER_CONSOLE` (y); `PWM_SAMSUNG` (m) |
| GPU | `DRM_PANFROST`, `DRM_SCHED` (m) |
| USB | `USB_DWC3`, `USB_DWC3_EXYNOS`, `USB_DWC3_GADGET`, `USB_CONFIGFS_ECM`, `USB_CONFIGFS_RNDIS`, `PHY_EXYNOS5_USBDRD` (y) |
| PCIe, Wi-Fi, Bluetooth | `PCI_EXYNOS`, `BRCMFMAC`, `CFG80211`, `BT`, `BT_HCIUART`, `BT_HCIUART_SERDEV` (m); `PHY_EXYNOS_PCIE`, `BT_HCIUART_BCM` (y) |
| I2C, SPI, serial | `I2C_EXYNOS5`, `I2C_GPIO` (y); `SPI_S3C64XX`, `SERIAL_SAMSUNG` (m) |
| Sound | `SND`, `SND_SOC`, `SND_SAMSUNG_I2S`, `SND_SOC_SAMSUNG_GTS28_WM1814`, `SND_SOC_WM8998`, `MFD_ARIZONA_I2C` (m); `MFD_WM8998` (y) |
| Input | `KEYBOARD_GPIO`, RMI4 (`RMI4_CORE`, `RMI4_I2C`, `RMI4_F11`, `RMI4_F12`), `HID`, `UHID` (y); `KEYBOARD_TC300K`, `INPUT_PWM_VIBRA` (m) |
| Sensors, cameras | `IIO`, `IIO_TRIGGER` (y); `IIO_ST_LSM6DSX*`, `YAMAHA_YAS530`, `VIDEO_T715_CAMERA`, `VIDEO_T715_SENSOR` (m) |
| ADC | `EXYNOS_ADC` (y) |
| RAM log, crash log | `SAMSUNG_SEC_LOG_CONSOLE`, `PSTORE`, `PSTORE_RAM`, `PSTORE_CONSOLE` (y) |
| CPU frequency, cooling | `CPU_FREQ`, `CPU_FREQ_DEFAULT_GOV_SCHEDUTIL`, `CPUFREQ_DT_PLATDEV`, `CPU_FREQ_THERMAL`, `PM_OPP`, `DEVFREQ_THERMAL` (y); `CPUFREQ_DT` (m) |
| Android, Waydroid | `ANDROID_BINDER_IPC` with `binder,hwbinder,vndbinder`, `BRIDGE`, `VLAN_8021Q`, `VETH`, `TUN`, `NF_TABLES`, the iptables legacy targets, `SQUASHFS` (y) |
| Root file systems | `EXT4_FS`, `VFAT_FS`, `EXFAT_FS`, `OVERLAY_FS`, `FUSE_FS` (y); `ZRAM`, `ZSMALLOC` (y) |

Not in the release either, so not here: `DM_CRYPT`, `CRYPTO_XTS` (no encrypted root), `KEXEC`,
`BTRFS_FS`, `XFS_FS`, and compression of firmware files (`FW_LOADER_COMPRESS` is off: the
firmware in the root must be uncompressed, as in the arm32 release).

## 4. The build

```
../build-arm64.sh                   # everything: configuration, Image, modules, device trees
../build-arm64.sh --config-only     # the configuration and the report only
../build-arm64.sh --clean           # empty the build volume first
```

- Container `t715-kbuild`, `--platform linux/arm64`, volume `t715-kbuild-arm64-port`, the clone
  read-only. `make ARCH=arm64 O=/build -j8 Image modules`. `DEBUG_INFO_NONE=y`: `vmlinux` has no
  debug section.
- **Identity.** A fixed one, as the owner's releases: `KBUILD_BUILD_TIMESTAMP` = the release's
  date, `KBUILD_BUILD_USER=t715-arm64`, `KBUILD_BUILD_HOST=port`, `KBUILD_BUILD_VERSION=1`. The
  banner reads `Linux version 6.12.114-00097-g512804d49581 (t715-arm64@port) (gcc 14.2.0, GNU ld
  2.44) #1 SMP PREEMPT Sat Nov 21 … UTC 2026`. Raise `KBUILD_BUILD_VERSION` to tell
  builds apart in `uname -a`.
- **Release string.** `6.12.114-00097-g512804d49581`: the kernel's own `scripts/setlocalversion`
  computed it from the clone (97 commits after `v6.12.114`), and the script passes it to the
  build because the view holds no repository. The modules directory has exactly this name, and
  all 71 modules carry it as vermagic. An uncommitted change adds `-dirty`.
- **Time.** About 20 minutes for a clean build with `-j8` on a machine shared with other builds;
  the configuration stage alone takes half a minute. `git` in the container compares only the
  modification time and the size of files (the index was written on the host): 6 seconds instead
  of 3 minutes for a `git status`.
- **Warnings.** One in the whole build: `fs/binfmt_elf.c:817`, a 1040-byte stack frame against
  the release's `FRAME_WARN=1024`. A warning only: one function's frame is 16 bytes over. No modpost
  warning, no section mismatch. `dtc` reports three, all in the board source as the release has
  it (the `memory` node without unit address, on purpose: S-Boot looks it up by name; two
  `graph_child_address` in mainline's `exynos5433.dtsi`), none in the overlay.
- To try an option: add a line to `../kernel/config/config-arm64.local` (same syntax as `.config`),
  run the script, delete the file. To change the kernel's arguments: edit
  `../kernel/config/bootargs-overlay.dts` and run the script.

## 5. Size

| | Bytes |
|---|---|
| `Image` (file: `_text` to `_edata`) | **15,523,848** (14.8 MiB), sha256 `1606bf78…0d85f2` |
| footprint in memory (`image_size` in the header, `.bss` included) | 15,990,784 (15.25 MiB) |
| of which code (`.text`) | 10,309,632 |
| read-only data (`.rodata`) | 2,397,136 |
| initialised data (`.data`) | 815,352 |
| `.bss` | 400,752 |
| init code and data, freed after boot | 1,376,256 |
| modules: 71 files, uncompressed | 6,299,888 (6.0 MiB); `modules.tar.xz` 1,086,440 |

The slot is 64 MiB = 67,108,864 bytes: a 4096-byte header, the Image and one device tree
(79,137 bytes) take 15,607,081, which leaves 51,501,783 bytes (49.1 MiB). The Image is
uncompressed, as the loader design wants.

What is built in, by area (code + read-only + initialised data of the 1914 objects of
`vmlinux`; the total of the objects is 13.4 MB):

| Bytes | Objects | Area |
|---:|---:|---|
| 2,125,302 | 190 | `kernel` (of which BPF 590,349; `printk` 503,007) |
| 2,657,749 | 444 | `net` (ipv4 657,693; core 612,665; ipv6 460,739; netfilter 438,378; bridge 200,201; sched 159,372; ethtool 128,701) |
| about 2,900,000 | — | `drivers` (gpu 525,349; clk 402,263; usb 328,616; base 256,708; pci 236,315; hid 225,888; input 195,470; tty 177,537; mmc 161,512; regulator 143,542; …) |
| 1,701,612 | 241 | `fs` (ext4 439,089) |
| 927,567 | 195 | `lib` (of which the zstd compressor 362,856: zram's backend) |
| 729,930 | 69 | `mm` |
| 266,107 | 86 | `arch/arm64` |
| 250,906 | 38 | `block` |
| 157,940 | 60 | `crypto` |

The board's own built-in drivers: 59 objects, 591,207 bytes. The largest are the 5433's clock
units (`clk-exynos5433.o`, 110,439), the S2MPS13 regulator tables (`s2mps11.o`, 68,458) and the
pinctrl driver (`pinctrl-exynos-arm64.o`, 20,353). About 127 KB of clock tables are for other
Samsung SoCs (Exynos 850, 7, 7885, Auto v9 and v9, GS101): `EXYNOS_ARM64_COMMON_CLK` brings them
all, and the release builds that too.

The 25 biggest symbols of `vmlinux`:

| Bytes | Symbol | |
|---:|---|---|
| 360,448 | `_printk_rb_static_infos` | the printk ring buffer |
| 131,072 | `__log_buf` | the 128 KiB log itself (`LOG_BUF_SHIFT=17`) |
| 98,304 | `_printk_rb_static_descs` | the printk ring buffer |
| 65,536 | `stack_pools` | VMAP stacks of interrupt handlers |
| 44,816 | `hid_usage_table` | HID |
| 24,576 | `__pi_ptes.1` | page tables of the identity map and of KPTI |
| 16,800 | `blocklist` | |
| 15,808 | `static_calls_table` | |
| 15,600 | `s2mps13_regulators` | the PMIC of this tablet |
| 15,240 | `edid_cea_modes_1` | |
| 14,976 | `s2mps11_regulators` | |
| 14,208 | `timer_bases` | |
| 13,728 | `ZSTD_compressBlock_doubleFast_dictMatchState` | zram |
| 13,188 | `hidinput_configure_usage` | |
| 13,112 | `ZSTD_compressBlock_fast` | zram |
| 12,664 | `ZSTD_compressBlock_fast_dictMatchState` | zram |
| 12,600 | `allowlist` | |
| 12,288 | `kpti_ptes` | page tables of KPTI |
| 12,288 | `idmap_ptes` | page tables of the identity map |
| 11,912 | `do_check_common` | |
| 11,728 | `ZSTD_compressBlock_doubleFast` | zram |
| 11,544 | `s2mps15_regulators` | another SoC's PMIC |
| 11,280 | `bpf_check` | |
| 10,920 | `s2mpu02_regulators` | another SoC's PMIC |
| 10,756 | `ext4_fill_super` | |

## 6. The device trees

- `gts28ltexx-base.dtb`: the board dts of the release tree, preprocessed and compiled by the
  tree's own `dtc` (1.7.0), `-b 0`. **It is the release's DTB byte for byte**: sha256
  `d7830adc83e0d169…b0292e`, 78,985 bytes, the hash the owner's `kernel/README.md` gives for 1.0.5.
- `gts28ltexx-bootargs.dtb`: the base with `bootargs-overlay.dts` applied by the tree's
  `fdtoverlay`. The decompiled trees differ on one line, the `bootargs` property: 77 characters
  (the dts's `console=tty0 loglevel=8 clk_ignore_unused pd_ignore_unused panic=5 oops=panic`)
  become our 229. 36 nodes are disabled in both: the overlay disables none. The script
  fails if the two trees differ by anything else. sha256 `46635d0f…39193`, 79,137 bytes.
- What the tree holds, for the record (the compiled tree, not the source): the root uses one
  address cell and one size cell, because S-Boot patches the tree of a 32-bit kernel; **six
  memory banks from `0x20000000` to `0xDE980000`**, 3,197,107,712 bytes (3049 MiB) of the
  3072; reserved: S-Boot's framebuffer, the log ring at `0x25fff000`, a 1 MiB ramoops at
  `0x26446000` (512 KiB records), Samsung's logs, the modem's shared memory, an ION carveout;
  **no `psci` node and no `enable-method`**: the board dts deletes them ("the bootloader offers
  no PSCI to a 32-bit kernel"); the vendor's handshake window `firmware@207b000` is there, for
  32-bit machine code. 203 devices carry a compatible, 36 are disabled.
- With the loader nothing rewrites the tree: S-Boot does not touch a device tree read from the
  CACHE slot, so the kernel sees the memory node as written.

## 7. Open issues

### 7.1 What does not exist on arm64, and the function lost

| Function | Why | State |
|---|---|---|
| The other seven cores | the 32-bit port starts them with `arch/arm/mach-exynos/platsmp.c` (boot address in sysram through the `samsung,secure-firmware` window, PMU power-up) and `firmware.c` (`SMC_CMD_CPU1BOOT` to the monitor), and manages clusters with `EXYNOS_MCPM` and `ARM_CCI400_PORT_CTRL`: all `arch/arm/`. The arm64 side selects only the clock, power domain, PMU and pinctrl drivers. The device tree gives arm64 nothing: no `enable-method`, no `psci` | **Lost** here; the eight-core method is the subject of `SMP-DESIGN.md` and `SMP-EXPERIMENT.md`. Until then `nosmp` or not, one core |
| Suspend to RAM | `EXYNOS_CPU_SUSPEND` is 32-bit machine code; `exynos5433_sleep=dryrun` in the built-in command line is meaningless on arm64 | **Lost**, then back on 2026-11-26: patch 0010 (`ARM64_EXYNOS5433_SUSPEND`), with `exynos5433_sleep=dryrun` in the device tree's arguments (`../kernel/README.md`) |
| The LTE modem (SS333) | `SEC_MODEM_V1` says `depends on ARM` (a module in the release). Its link driver `MIPI_LLI` is still built, with nothing to use it | **Lost** until the driver is ported. Separate work |
| Hot-unplug of the A57 cluster | 32-bit machine code: `arch/arm/mach-exynos/platsmp.c` and `firmware.c` (`SMC_CMD_SHUTDOWN`) | **Lost** with the secondary cores, then back on 2026-11-26: patch 0010, the monitor's shutdown call from AArch64 (`FINDINGS.md`, section 23) |
| 32-bit userland, 32-bit Android in Waydroid | `COMPAT` off (as decided) | Only a 64-bit Android image could run; `COMPAT` is on since 2.1.0, for Waydroid's arm64 image and its 32-bit services and apps |

### 7.2 The modules, and what loads them

71 files for 66 `=m` options (`BRCMFMAC` gives four modules, `SND_SAMSUNG_I2S` and `VIDEO_DEV`
two each; three more `=m` options only add parts to other modules). Of the 66, 65 are the
release's and one is new, `arm_smccc_trng`; the release's 69th, the modem driver, is gone. None is needed to
mount a root on the eMMC (the MMC host and ext4 are built in), so a system without modules
boots. What then does not work: the GPU, CPU frequency scaling, sound, Wi-Fi, Bluetooth, the
touch keys, the vibrator, the sensors, the cameras.

**Once the modules are installed, udev loads them by itself.** From `modules.alias` and the
board tree: 17 modules answer a device of the tree and load when it is probed (`panfrost` for
`gpu@14ac0000`, `cpufreq-dt` for the platform device the kernel creates per CPU with an OPP
table, `pci-exynos` then `brcmfmac`, the sound stack, the sensors, the cameras, …), 22 load
through an alias of a device that is enumerated or a protocol that is used, 24 are dependencies
of those, 8 are loaded by name or not at all.

So the kernel itself scales nothing (the owner's rule, met: `nosmp`, S-Boot's frequencies), but
**`cpufreq-dt` and `panfrost` start scaling the CPU and the GPU as soon as udev runs**, by the
board's own tables, on drivers that have never run on arm64 here. The owner's practice for test
kernels is to blacklist `cpufreq_dt` (their initramfs has `t715.modblacklist=`); the kernel's
own parameter `modprobe.blacklist=cpufreq_dt,panfrost` does the same from the command line. And
without `cpufreq-dt` the cooling maps have nothing to act on: fine at rest, not under load.

| Module | Option | What loads it | Needed by |
|---|---|---|---|
| `arizona` | `MFD_ARIZONA` | a dependency of another module: pulled in with it | arizona-i2c, snd-soc-arizona, snd-soc-wm8998 |
| `arizona-i2c` | `MFD_ARIZONA_I2C` | udev, for `//soc@0/i2c@14e70000/audio-codec@1a` (wlf,wm1814) | - |
| `arizona-ldo1` | `REGULATOR_ARIZONA_LDO1` | Udev, when the kernel creates the platform device of a driver that needs it | - |
| `arizona-micsupp` | `REGULATOR_ARIZONA_MICSUPP` | Udev, when the kernel creates the platform device of a driver that needs it | - |
| `arm_smccc_trng` | `HW_RANDOM_ARM_SMCCC_TRNG` | udev would, for the `smccc_trng` device; the kernel never creates it here (no SMCCC conduit) | - |
| `bluetooth` | `BT` | The Bluetooth stack, when a Bluetooth socket is opened | hci_uart, btbcm, rfcomm, bnep, hidp |
| `bnep` | `BT_BNEP` | The Bluetooth stack, when BNEP is used | - |
| `brcmfmac` | `BRCMFMAC` | Udev, when a PCI device of that id is enumerated; udev, when an SDIO device of that id is enumerated | brcmfmac-wcc, brcmfmac-cyw, brcmfmac-bca |
| `brcmfmac-bca` | `BRCMFMAC` | The kernel: brcmfmac asks for it by name (fwvid.c, request_module) | - |
| `brcmfmac-cyw` | `BRCMFMAC` | The kernel: brcmfmac asks for it by name (fwvid.c, request_module) | - |
| `brcmfmac-wcc` | `BRCMFMAC` | The kernel: brcmfmac asks for `brcmfmac-<vendor>` by name (fwvid.c, request_module) once it knows the chip's firmware vendor | - |
| `brcmutil` | `BRCMUTIL` | a dependency of another module: pulled in with it | brcmfmac, brcmfmac-wcc, brcmfmac-cyw, brcmfmac-bca |
| `btbcm` | `BT_BCM` | a dependency of another module: pulled in with it | hci_uart |
| `cfg80211` | `CFG80211` | When the nl80211 socket family is opened; and brcmfmac | brcmfmac, brcmfmac-wcc, brcmfmac-cyw, brcmfmac-bca |
| `cmac` | `CRYPTO_CMAC` | Cmac; crypto-cmac | - |
| `cpufreq-dt` | `CPUFREQ_DT` | **udev, at boot**: the kernel creates a `cpufreq-dt` platform device for each CPU that has an OPP table (CPUFREQ_DT_PLATDEV=y) | - |
| `dwc3-haps` | `USB_DWC3_HAPS` | Udev, when a PCI device of that id is enumerated | - |
| `dwc3-of-simple` | `USB_DWC3_OF_SIMPLE` | Nothing here: its node (a plain `snps,dwc3` wrapper) is not in the board tree | - |
| `ecc` | `CRYPTO_ECC` | a dependency of another module: pulled in with it | ecdh_generic, hci_uart, btbcm, bluetooth, rfcomm, bnep, hidp |
| `ecdh_generic` | `CRYPTO_ECDH` | Crypto-ecdh; ecdh | hci_uart, btbcm, bluetooth, rfcomm, bnep, hidp |
| `exynos-lpass` | `MFD_EXYNOS_LPASS` | udev, for `//soc@0/audio-subsystem@11400000` (samsung,exynos5433-lpass) | - |
| `exynos-trng` | `HW_RANDOM_EXYNOS` | Nothing here: its aliases are the Exynos 5250 and 850 TRNG, and the board tree has no TRNG node (as in the release) | - |
| `exynos5433-mipi-lli` | `MIPI_LLI` | By name only: the SS333 modem link, whose modem driver (SEC_MODEM_V1) does not exist on arm64 | - |
| `gpio-arizona` | `GPIO_ARIZONA` | Udev, when the kernel creates the platform device of a driver that needs it | - |
| `gpu-sched` | `DRM_SCHED` | a dependency of another module: pulled in with it | panfrost |
| `hci_uart` | `BT_HCIUART` | udev, for `//soc@0/audio-subsystem@11400000/serial@11460000/bluetooth` (brcm,bcm43540-bt) | - |
| `hidp` | `BT_HIDP` | The Bluetooth stack, when HIDP is used | - |
| `i2c-mux` | `I2C_MUX` | By name only; no I2C multiplexer in the board tree | - |
| `industrialio-triggered-buffer` | `IIO_TRIGGERED_BUFFER` | a dependency of another module: pulled in with it | st_lsm6dsx, st_lsm6dsx_i2c, st_lsm6dsx_spi, yamaha-yas530 |
| `kfifo_buf` | `IIO_KFIFO_BUF` | a dependency of another module: pulled in with it | industrialio-triggered-buffer, st_lsm6dsx, st_lsm6dsx_i2c, st_lsm6dsx_spi, yamaha-yas530 |
| `mc` | `MEDIA_SUPPORT` | a dependency of another module: pulled in with it | t715-sensor, videobuf2-common, videobuf2-dma-contig, videobuf2-memops, videobuf2-v4l2, t715-camera, v4l2-async, v4l2-fwnode, videodev |
| `panfrost` | `DRM_PANFROST` | udev, for `//soc@0/gpu@14ac0000` (samsung,exynos5433-mali) | - |
| `pci-exynos` | `PCI_EXYNOS` | udev, for `//soc@0/pcie@15700000` (samsung,exynos5433-pcie) | - |
| `pl330` | `PL330_DMA` | udev, when the kernel creates the AMBA device (the three arm,pl330 DMA controllers) | - |
| `pwm-samsung` | `PWM_SAMSUNG` | udev, for `//soc@0/pwm@14dd0000` (samsung,exynos5433-pwm) | - |
| `pwm-vibra` | `INPUT_PWM_VIBRA` | udev, for `//vibrator` (pwm-vibrator) | - |
| `regmap-spi` | `REGMAP_SPI` | a dependency of another module: pulled in with it | st_lsm6dsx_spi |
| `rfcomm` | `BT_RFCOMM` | The Bluetooth stack, when RFCOMM is used | - |
| `rfkill` | `RFKILL` | Udev, when /dev/rfkill appears; udev, when its device node appears | brcmfmac, brcmfmac-wcc, brcmfmac-cyw, brcmfmac-bca, hci_uart, btbcm, cfg80211, bluetooth, rfcomm, bnep, hidp |
| `rng-core` | `HW_RANDOM` | a dependency of another module: pulled in with it | exynos-trng, arm_smccc_trng |
| `samsung_tty` | `SERIAL_SAMSUNG` | udev, for `//soc@0/serial@14c10000` (samsung,exynos5433-uart) | - |
| `serial_base` | `SERIAL_CORE` | a dependency of another module: pulled in with it | samsung_tty |
| `snd` | `SND` | Udev, when an ALSA device node appears | arizona-micsupp, snd-timer, snd-pcm, snd-pcm-dmaengine, snd-soc-core, snd-soc-arizona, snd-soc-hdmi-codec, snd-soc-wm8998, snd-soc-s3c-dma, snd-soc-i2s, snd-soc-idma, snd-soc-gts28-wm1814 |
| `snd-pcm` | `SND_PCM` | a dependency of another module: pulled in with it | arizona-micsupp, snd-pcm-dmaengine, snd-soc-core, snd-soc-arizona, snd-soc-hdmi-codec, snd-soc-wm8998, snd-soc-s3c-dma, snd-soc-i2s, snd-soc-idma, snd-soc-gts28-wm1814 |
| `snd-pcm-dmaengine` | `SND_DMAENGINE_PCM` | a dependency of another module: pulled in with it | arizona-micsupp, snd-soc-core, snd-soc-arizona, snd-soc-hdmi-codec, snd-soc-wm8998, snd-soc-s3c-dma, snd-soc-i2s, snd-soc-idma, snd-soc-gts28-wm1814 |
| `snd-soc-arizona` | `SND_SOC_ARIZONA` | a dependency of another module: pulled in with it | snd-soc-wm8998 |
| `snd-soc-core` | `SND_SOC` | Udev, when the kernel creates the platform device of a driver that needs it | arizona-micsupp, snd-soc-arizona, snd-soc-hdmi-codec, snd-soc-wm8998, snd-soc-s3c-dma, snd-soc-i2s, snd-soc-idma, snd-soc-gts28-wm1814 |
| `snd-soc-gts28-wm1814` | `SND_SOC_SAMSUNG_GTS28_WM1814` | udev, for `//sound` (samsung,gts28-wm1814) | - |
| `snd-soc-hdmi-codec` | `SND_SOC_HDMI_CODEC` | Udev, when the kernel creates the platform device of a driver that needs it | - |
| `snd-soc-i2s` | `SND_SAMSUNG_I2S` | udev, for `//soc@0/i2s@14d60000, disabled` (samsung,exynos5433-i2s), a disabled node | - |
| `snd-soc-idma` | `SND_SAMSUNG_I2S` | a dependency of another module: pulled in with it | snd-soc-i2s |
| `snd-soc-s3c-dma` | `SND_SOC_SAMSUNG` | a dependency of another module: pulled in with it | snd-soc-i2s |
| `snd-soc-wm8998` | `SND_SOC_WM8998` | Udev, when the kernel creates the platform device of a driver that needs it | - |
| `snd-timer` | `SND_TIMER` | Udev, when the ALSA timer device appears; udev, when its device node appears | arizona-micsupp, snd-pcm, snd-pcm-dmaengine, snd-soc-core, snd-soc-arizona, snd-soc-hdmi-codec, snd-soc-wm8998, snd-soc-s3c-dma, snd-soc-i2s, snd-soc-idma, snd-soc-gts28-wm1814 |
| `spi-s3c64xx` | `SPI_S3C64XX` | udev, for `//soc@0/spi@14d20000, disabled` (samsung,exynos5433-spi), a disabled node | - |
| `st_lsm6dsx` | `IIO_ST_LSM6DSX` | a dependency of another module: pulled in with it | st_lsm6dsx_i2c, st_lsm6dsx_spi |
| `st_lsm6dsx_i2c` | `IIO_ST_LSM6DSX_I2C` | udev, for `//soc@0/i2c@14de0000/imu@6b` (st,lsm6ds3) | - |
| `st_lsm6dsx_spi` | `IIO_ST_LSM6DSX_SPI` | udev, for `//soc@0/i2c@14de0000/imu@6b` (st,lsm6ds3) | - |
| `t715-camera` | `VIDEO_T715_CAMERA` | udev, for `//soc@0/camera@12120000` (samsung,t715-camera-rear) | - |
| `t715-sensor` | `VIDEO_T715_SENSOR` | udev, for `//i2c-cam-front/camera-sensor@35` (samsung,s5k6b2) | - |
| `tc300k` | `KEYBOARD_TC300K` | udev, for `//soc@0/i2c@14da0000/touchkey@20` (coreriver,tc300-keypad) | - |
| `v4l2-async` | `V4L2_ASYNC` | a dependency of another module: pulled in with it | t715-sensor, t715-camera, v4l2-fwnode |
| `v4l2-cci` | `V4L2_CCI` | a dependency of another module: pulled in with it | t715-sensor |
| `v4l2-dv-timings` | `VIDEO_DEV` | By name only (the video timing helpers of VIDEO_DEV) | - |
| `v4l2-fwnode` | `V4L2_FWNODE` | a dependency of another module: pulled in with it | t715-sensor, t715-camera |
| `videobuf2-common` | `VIDEOBUF2_CORE` | a dependency of another module: pulled in with it | videobuf2-dma-contig, videobuf2-memops, videobuf2-v4l2, t715-camera |
| `videobuf2-dma-contig` | `VIDEOBUF2_DMA_CONTIG` | a dependency of another module: pulled in with it | t715-camera |
| `videobuf2-memops` | `VIDEOBUF2_MEMOPS` | a dependency of another module: pulled in with it | videobuf2-dma-contig, t715-camera |
| `videobuf2-v4l2` | `VIDEOBUF2_V4L2` | a dependency of another module: pulled in with it | t715-camera |
| `videodev` | `VIDEO_DEV` | Udev, when a video device node appears | t715-sensor, videobuf2-v4l2, t715-camera, v4l2-async, v4l2-fwnode |
| `yamaha-yas530` | `YAMAHA_YAS530` | udev, for `//soc@0/i2c@14de0000/magnetometer@2e` (yamaha,yas537) | - |

### 7.3 Surprises

1. **The case-insensitive clone** (§2.3): the first full build failed on it. The same trap waits
   in any clone of this tree made on a case-insensitive disk.
2. **No PSCI, and no firmware call at all.** With this tree the kernel never issues an SMC: the
   SMCCC conduit is established in one function, called by the PSCI code only, and there is no
   `psci` node. Everything in the kernel that asks the firmware (the Spectre-BHB firmware
   workaround, the TRNG probe, the SoC id) is skipped. **If a later tree adds a PSCI 0.2+ node**
   (the natural way to start the other cores), all of that starts calling the secure monitor
   through SMCs it has not been asked on this path: to be tested deliberately.
3. **`EXYNOS_IOMMU` is not in the release** (§3.3, 7).
4. **The regulator coupler, `EXYNOS_ASV_ARM` and `EXYNOS_PMU_ARM_DRIVERS` do nothing on this
   SoC**; our list expected the coupler.
5. **The memory node.** The design decided on 2026-11-24 says the kernel sees RAM at
   `0x40000000..0xBEA00000`; the tree gives it six banks from `0x20000000` to `0xDE980000`.
   The log of our first boot is the reference. The loader's own buffers (`0x24F00000` and up,
   the log ring at `0x26000000`) lie in the first bank, which the tree declares as RAM, with
   the ring reserved by a node.
6. **The command line** (§3.3, 3): the built-in string is a fallback only. Booting the base DTB
   without the overlay starts with the dts's arguments: no RAM log console, and the watchdog
   core keeps feeding the watchdog during boot (`WATCHDOG_HANDLE_BOOT_ENABLED=y` is the
   configuration; the overlay's `watchdog.handle_boot_enabled=0` is what turns it off).
7. **More arm64 defaults than in the tested kernel.** Our minimal kernel came from
   `allnoconfig`, which turns prompted defaults off; this one is the release translated, so
   `RODATA_FULL_DEFAULT_ENABLED`, `KERNEL_MODE_NEON`, `RELOCATABLE`, `RELR`, the errata and the
   mitigations are on. They are standard arm64 behaviour, and none ran on the tablet yet.
8. **Firmware files must be uncompressed** in the root (`FW_LOADER_COMPRESS` off, as in the
   release).
9. **Three modules are large for what they do here**: `snd-soc-wm8998.ko` (1.59 MB),
   `bluetooth.ko` (0.9 MB), `cfg80211.ko` (0.57 MB). Built in, the printk ring buffer's
   bookkeeping weighs 575 KiB for a 128 KiB log, and the zstd compressor 354 KiB.

## 8. What was verified, and what was not

Verified, by commands, on 2026-11-24:

- the clone: branch, empty `git status`, HEAD, and the commit is the release content plus the
  our file byte for byte; the owner's trees unchanged (their `git status` stayed empty);
- the translation: by Kconfig text and by the kernel's evaluator, with controls; 153 gone, 231
  new, 1208 unchanged, each with its reason, no symbol left; the 17 `COMPILE_TEST` symbols each
  checked against the driver source and the compiled tree;
- the build: `vmlinux` ELF64 AArch64, no debug section; the effective macros (`ARM64_VA_BITS 39`,
  `ARM64_PA_BITS 48`, `PGTABLE_LEVELS 3`); the Image header (`ARMd`, `text_offset` 0,
  `image_size` 15,990,784); the patch's message in the image; the TCPMSS target and the HL match
  in `vmlinux`;
- the device trees: the base equal to the release's DTB; the overlay changing one line;
- the modules: 71, all with the kernel's release string, each mapped to its Kconfig option
  through the tree's Makefiles.

Not verified: everything that needs the tablet. No kernel described here was booted; no
driver was run; the RAM log, the watchdog, the restart, the PM domains, the regulators, the
display, the GPU, the radios, the sensors are untested on arm64 with this configuration, as is
the MCT patch with a kernel of this size.

## State on 2026-11-26

**Proven on the tablet.** The full kernel booted on the tablet with a root image on 2026-11-25: the
release configuration translated to arm64, with the eight-core method (`samsung,exynos5433-el2`, no
PSCI), stage 1 and the initramfs built in. The loader starts it from a slot of CACHE, with the MCT as
the time base (the ARM counter does not run); a failed attempt gives the tablet back to the 32-bit
system by itself. The arm64 system replaces the 32-bit one (the owner's decision, 2026-11-24): cold
boot by the power key reaches user space in 12 s; a reboot is back in 32 s, user space in 13 s. As
far as the health check sees (drivers bound, devices present, Wi-Fi associated and online), display,
touch, GPU (panfrost), Wi-Fi, Bluetooth, sound, sensors, battery and charger, microSD work on arm64.
With the System MMUs disabled in the board tree (`../kernel/patches/0008`) and `quiet splash`, the
boot screen shows the splash from 4.7 to 8.6 s. A soak of several hours with twelve 3-min phases of
eight busy cores ended without a reboot: atlas peak 94 °C, cooling to 0.9/1.0 GHz. The modem's CP
comes up at every boot, ONLINE in 9.9 s after `KBOOT: up` (`sec_modem_v1` built for arm64,
`../kernel/patches/0009`). On 2026-11-26, the kernel of omarchy-tab-s2 2.1.0
(`6.12.114-00106-gd30e37ad41ab`: `../kernel/patches/0010`, `ARM64_EXYNOS5433_SUSPEND` and `COMPAT`):
the seven secondaries down and back, four rounds, and five real sleeps out of five
(`FINDINGS.md`, section 23).

**Built or rehearsed only.** The health check is not use: touch gestures, rotation, sound out,
Bluetooth pairing and the camera have not been tried by a hand. The modem tools built for aarch64
(`t715-mobile`, omaphone, omamessages) have not run with a SIM: there is none in the tablet.

**Open.** The A57 above 1.2 GHz (stage 2; `CPUFREQ-THERMAL.md`); the modem with a SIM
(registration, mobile data, SMS, calls with audio); about 4 s of text before the splash (an
initramfs `t715.quiet`, at the next kernel build); the compositor's first Panfrost → exynos-drm imports, which fail on non-contiguous
buffers (78 errors in the session's first 40 s) before it falls back; a fresh root's first boot,
which has no Wi-Fi; pstore records, not archived at boot (systemd-pstore is off); `schedutil` under
real use; idle power.
