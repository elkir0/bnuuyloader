# CPU idle without PSCI on the SM-T715 (arm64)

State of 2026-11-27. The 64-bit kernel of omarchy-tab-s2 2.1.x had no cpuidle at all: no
`CONFIG_CPU_IDLE`, and no `/sys/devices/system/cpu/cpuidle`. Every idle core sat in WFI, still
powered, at the frequency its cluster ran at. The firmware offers no PSCI, so neither
`cpuidle-psci` nor `cpuidle-arm` can reach anything deeper. This note says what was built
instead, what proved it, and what it saves.

## 1. The state: the vendor kernel's per-core C2

The vendor kernel (Samsung 3.10, `cpuidle-exynos5433.c`) has five idle states. The study of the
32-bit port (omarchy-tab-s2 `research/cpuidle/FINDINGS.md`) ranks them. Its second step is the
per-core power-down "C2", entered through the secure monitor. The 64-bit port already had what that
state needs:

- the monitor's `SHUTDOWN` call made from AArch64 (patch 0010, hot-unplug);
- the way back from a power-down to `cpu_resume`, through an AArch32 stub
  (`exynos5433_resume_entry`), `SMC 0x82000400` to EL2, and `eret` to EL1 (patch 0010, system
  sleep and `c2test`).

The entry, as stock does it, for one core:

1. The resume address goes to sysram-ns + 0x24 and the magic `0xFCBA0D10` to + 0x20.
2. The core's flag word (sysram-ns + 0x28 + 4 × PMU index) gets bit 3 (C2).
3. Inside `cpu_suspend()`, the finisher turns the core's local power request off (PMU
   `ARM_CORE_CONFIGURATION`), then calls the monitor's `SAVE(CORE, IDLE)` and `SHUTDOWN(CORE,
   IDLE)`. The monitor cleans the caches, takes the core out of coherency and powers it down at
   its WFI.

The monitor's stub sends a core whose flag has bit 3 to the address at + 0x24, and only then
(`docs/arm64-monitor-smc.md` of the port, section 5.3). The boot register at + 0x1C, which starts
the secondaries, is never involved. A system sleep resets + 0x24, so the driver writes it on every
entry.

## 2. The question, and the test that settled it: `c2wake`

An idle state is only usable if a powered-down core comes back by itself when an interrupt reaches
it. `c2test` (patch 0010) powers the core back on by hand from CPU0, so it says nothing about that.

`c2wake` (`/sys/module/smp_exynos5433/parameters/c2wake`, a test hook in `smp_exynos5433.c`)
works like this:

1. It puts one secondary into stock's C2.
2. It waits until the PMU shows the core off.
3. It sends the core an IPI and waits 100 ms for it to come back by itself.
4. If the core does not come back, it powers the core on by hand, as `c2test` does. A failed try
   costs nothing.

On the reference tablet, 2026-11-27:

- **Seventy tries on cores 1 to 7** (A53 and A57). Every core came back by itself: on the IPI, or
  on its own interrupts before the IPI (its MCT tick). It went down in about 50 µs and came back
  60 to 70 µs after the IPI.
- **The firmware already enables the PMU's automatic wake-up.** `ARM_CORE_CONFIGURATION` reads
  `0x8000000f` (bit 31) before the power-down, and again on the core's return: the PMU restored the
  power request itself.
- **An interrupt already pending is an early wake-up.** The monitor returns without powering the
  core down: the finisher returns 1, and `CONFIGURATION` reads `0x80000000`. The power request must
  then be set back by hand before the next WFI, as stock's `exynos5433_cpu_up()` does. Two of the
  seventy tries did this.
- **Nothing was lost.** No core was lost, and the system stayed up throughout.

## 3. The driver

- **`exynos5433_c2_suspend()`** in `arch/arm64/kernel/smp_exynos5433.c`:
  - It is the entry above, for the calling CPU.
  - It sets the power request back after an early wake-up.
  - It clears bit 3 on the way out.
  - It refuses the boot CPU: a warm boot of the boot CPU with a flag other than 8 reruns the
    monitor's cold init.
  - It is called through `CPU_PM_CPU_IDLE_ENTER_PARAM_RCU(exynos5433_c2_suspend, idx, idx)`, so
    it runs between `cpu_pm_enter()` and `cpu_pm_exit()` with RCU off.
- **`drivers/cpuidle/cpuidle-exynos5433.c`** (`CONFIG_ARM64_EXYNOS5433_CPUIDLE`, which selects
  `CPU_IDLE_MULTIPLE_DRIVERS`) registers three drivers. The patch carrying the driver, `c2wake`,
  the hot-plug race fix and the context-tracking fix is
  `t715/kernel/patches/0011-arm64-exynos5433-cpuidle-C2-per-core-without-PSCI.patch`:

  | CPUs | States | C2 target residency |
  |---|---|---|
  | CPU0 (boot) | WFI | — |
  | 1-3 (A53) | WFI, C2 | 750 µs (stock's) |
  | 4-7 (A57) | WFI, C2 | 2000 µs (stock's) |

  - The exit latency is 150 µs: the measured power-down and wake-up, with some room.
  - No `local-timer-stop`: the per-CPU MCT comparators sit outside the cores, and woke cores in C2
    in the test.
  - The governor is menu.
- **Off at boot in the driver, on in the daily arguments.** Without
  `cpuidle_exynos5433.enable=1` on the command line the driver registers nothing. The daily
  kernel arguments (`t715/kernel/config/bootargs-daily.dts`) now carry it, with
  `smp_exynos5433.hotplug=1` (the A57 hot-unplug that the image's `t715-keys` uses while the
  screen is dark; the image's udev rule `60-t715-big-cores.rules` makes the online files
  writable for the session user) and `workqueue.power_efficient=1`. By hand,
  `echo 1 > /sys/module/cpuidle_exynos5433/parameters/enable` registers it at `late_initcall`.
  A kernel whose C2 misbehaves therefore still boots.
- **Off again** for a state and a CPU: `/sys/devices/system/cpu/cpuN/cpuidle/state1/disable`.
- **EMA:** the A57 EMA that `exynos5433-atlas-asv` writes sits in the cluster's SYSREG
  (`0x11810330`), not in the core. A per-core power-down keeps it.

On the tablet, with the driver on, in the first 10 s:

- CPU1 entered C2 2160 times (6 s of the 10), with 287 early wake-ups;
- CPU4 and CPU7 (A57) entered it 909 and 813 times.

### Hot-plug with C2 on

The first A57 hot-plug test with the driver on lost two cores. A core brought online reached the
kernel and went into C2 before `exynos5433_cpu_boot()` looked at the PMU. The boot poll then read
the core off for its full 10 ms, reported a power-up timeout, and the kernel marked the core
`SMP_FAILED` until the next reboot.

The poll now also counts the core's arrival in the kernel (`exynos5433_arrived`) as powered. With
that kernel (slot generation 19), 2026-11-27: 20 cycles of CPUs 7 to 4 offline and back, C2 on.
None failed, and in 62 of the 80 power-ups the poll found the core already back in C2.

### Context tracking

The driver entered C2 with `CPU_PM_CPU_IDLE_ENTER()`, which calls `ct_cpuidle_enter()` itself.
arm64's `cpu_suspend()` calls it again, so context tracking was entered twice: a `WARN` at
`kernel/context_tracking.c:128` (`ct_kernel_exit`) on the first C2 entry of each A57, at boot.
The counts balance on the way out, which is why hours of use showed nothing else. The nesting
was still wrong.

The driver now uses `CPU_PM_CPU_IDLE_ENTER_PARAM_RCU(exynos5433_c2_suspend, idx, idx)`, as
`cpuidle-psci` does, with `CPUIDLE_FLAG_RCU_IDLE` on C2. WFI (index 0) has no flag, so the
cpuidle core does the context tracking around `cpu_do_idle()`. With the fix: no warning from
boot (slot generation 21).

## 4. What it saves

The measurement ran on battery: screen on and idle, sleep and idle inhibited, the charger
unplugged. Four phases of 150 s, C2 off and on in turn, the battery read every 5 s (26 samples a
phase):

| Phase | C2 | Current | Power |
|---|---|---|---|
| 1 | off (WFI only) | 647 mA | 2318 mW |
| 2 | on | 627 mA | 2239 mW |
| 3 | off | 659 mA | 2348 mW |
| 4 | on | 626 mA | 2224 mW |

The two phases with C2 on entered it 44614 and 46250 times. **C2 saves about 27 mA, about
100 mW: 4.3 % of 2.33 W.** Both pairs agree, and the spread within a phase is 60 to 80 mA. Most of
the 2.3 W drawn with the screen on and idle is not in idle cores.

### The A57 cluster offline against C2 alone

Measured 2026-11-27 with the method of ENERGY-MODEL.md, section 1: on the Mac's USB port, screen
dark, sleep and idle inhibited, the charger's input at its 450 mA limit, so a change in the
system's draw shows one for one in the battery current. C2 was on in all phases. "Offline" means
CPUs 4-7 hot-unplugged: patch 0010 powers the cluster down with its last core. Phases alternated
between the two states, 20 s to settle each, the fuel gauge read once a second (120 samples a
phase); the spread within a phase is 60-120 mA per sample, so a single pair of phases is only
good to about ±50 mW and the conclusion uses the mean of three pairs.

| Phase | A57 | Battery current | Power into the battery |
|---|---|---|---|
| 1 | online | 174.0 mA | 668 mW |
| 2 | offline | 183.6 mA | 705 mW |
| 3 | online | 147.7 mA | 567 mW |
| 4 | offline | 185.5 mA | 712 mW |
| 5 | online | 156.0 mA | 598 mW |
| 6 | offline | 190.8 mA | 733 mW |

The three pairs give 37, 145 and 133 mW. **The A57 cluster offline saves about 105 mW** of
system power with the screen dark, on top of C2. With all four A57 in C2, the cluster's non-CPU
part (L2, etc.) stays powered, and that is what this measures. In the offline phases the A53s
entered C2 more often: about 48,000 entries per 130 s, against about 40,000.

## 5. What is open

- **A longer soak under real use.** A synthetic soak of ten rounds (55 min) on 2026-11-27 passed
  without a warning (ENERGY-MODEL.md, section 6). Real interactive use, with the screen lit, is
  still to come.
- **Cluster power-down: measured.** The A57 cluster offline saves about 105 mW with the screen
  dark, on top of C2 (§4). The cheap way, hot-unplug while the screen is dark, is what the daily
  system now does (`smp_exynos5433.hotplug=1`). Stock's C2-1 (the cluster down from idle, with a
  four-core rendezvous) stays unstudied.
- **CPU0.** WFI only. Its C2 would go through the monitor's cold init, and is not studied.
- **Where the rest of the 2.3 W goes.** Panel and backlight, the GPU, the modem's processor, the
  Wi-Fi.
