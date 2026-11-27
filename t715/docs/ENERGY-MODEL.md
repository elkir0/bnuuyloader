# The energy model and EAS on the SM-T715 (arm64)

State of 2026-11-27. The 64-bit kernel had CPU capacities but no energy model, so energy-aware
scheduling (EAS) was off. This note says what was added, how the model's coefficients were
measured on the reference tablet on 2026-11-27, what EAS saves under a UI-like load, and what
none of this shows. The device tree side is patch
`t715/kernel/patches/0012-arm64-dts-exynos-gts28ltexx-the-energy-model-for-EAS.patch`.

## 1. The measurement method

The tablet was on the Mac's USB port, screen dark (DRM DPMS "Off"), sleep and idle inhibited
(`systemd-inhibit --what=sleep:idle`). The SM5703 charger's input limit on that port is 450 mA,
and its constant charge current is 450 mA. The battery charged at about 150-250 mA at idle, so
the input sat at its limit. The input power is then fixed, and any change in the system's draw
shows up one for one in the battery current: dP_system = -V_bat × dI_bat (`current_now` > 0
while charging).

Phases alternate between the two states compared, with 20 s to settle each. The fuel gauge was
read once per second: 120 samples a phase. For the energy model it was every 5 s, 12 samples.
Within a phase, the spread (standard deviation) is 60-120 mA per sample. So a single pair of
phases is only good to about ±50 mW, and the conclusions use the mean of three pairs.

## 2. Before and after

**Before.** The kernel had `capacity-dmips-mhz` (2048 for the A53s and 3575 for the A57s, from the
32-bit board file), so the CPU capacities were 586 and 1024. It had no energy model:
`CONFIG_ENERGY_MODEL` was not set and no `dynamic-power-coefficient` existed, so EAS was off and
`/proc/sys/kernel/sched_energy_aware` was absent.

**After.**

- `CONFIG_ENERGY_MODEL=y` (`t715/kernel/config/config-arm64.local`).
- Each CPU node gets `dynamic-power-coefficient`: 177 for the A53s, 648 for the A57s. The kernel
  side is in `arch/arm64/boot/dts/exynos/exynos5433-gts28ltexx-eas.dtsi`, included by the arm64
  board DTS (patch 0012, above).
- cpufreq-dt registers one perf domain per cluster: `/sys/kernel/debug/energy_model/cpu0` and
  `cpu4`, with 8 and 5 perf states. `sched_energy_aware` reads 1.

The DT binding's model is P[µW] = C × f[MHz] × V[V]².

## 3. The OPP tables

This tablet's tables, the A57 capped at 1.2 GHz by patch 0007:

| | 400 MHz | 500 | 600 | 800 | 900 | 1000 | 1100 | 1200 MHz |
|---|---|---|---|---|---|---|---|---|
| A53 | 0.8750 V | 0.9125 | 0.9375 | 1.0000 | 1.0250 | 1.0875 | 1.1250 | 1.1625 |
| A57 | — | — | — | 0.9875 | 1.0125 | 1.0125 | 1.0375 | 1.0625 |

## 4. The dynamic power coefficient, and the capacities

**Measuring C.** Method of section 1. Both clusters were pinned to one frequency (`scaling_min` =
`scaling_max`). Phases of 70 s: idle, three busy A53 (CPUs 1-3), idle, four busy A57 (CPUs 4-7),
idle. The busy loop was a shell `while :; do :; done` pinned with `taskset`, and C2 was on. Power
per busy core = (idle current, the mean of the idle phases before and after − busy current) × V
/ cores:

| Cluster | Frequency | Voltage | Per busy core over idle | C (µW/MHz/V²) |
|---|---|---|---|---|
| A53 | 800 MHz | 1.0000 V | 146 mW | 182 |
| A53 | 1200 MHz | 1.1625 V | 280 mW | 172 |
| A57 | 800 MHz | 0.9875 V | 497 mW | 636 |
| A57 | 1200 MHz | 1.0625 V | 896 mW | 661 |

The model holds across frequencies within 6 %. The value kept is the mean of the two: 177 for
the A53s, 648 for the A57s. During the four-A57 phase at 1.2 GHz the A57 sensors read 64-70 °C,
so that point carries some leakage. Busy over idle includes the static power of a core that is
otherwise in C2, so C is a little high for both clusters alike.

**Energy per unit of capacity** (power / capacity at that frequency):

- an A53 at 1.2 GHz: 0.48 mW per unit;
- an A57 at 800 MHz: 0.73 (capacity 683);
- an A57 at 1.2 GHz: 0.88.

An A53 runs the same work for less energy at every frequency here.

**Checking the capacities.** Work per clock, an A53 (CPU1) against an A57 (CPU4), both at
1.2 GHz, the best of three runs each:

| Workload | A53 | A57 | A53/A57 work per clock |
|---|---|---|---|
| Python integer loop (1.5 M steps) | 4019 ms | 2092 ms | 0.521 |
| xz -6, 4 MB | 3523 ms | 1891 ms | 0.537 |
| gzip -6, 4 MB twice | 1170 ms | 860 ms | 0.735 |

The board's capacities say 2048/3575 = 0.573, between these values (geometric mean 0.59). They
stay as they are.

## 5. EAS on against off

The load is `uiload.py`: three processes, each with a frame every 16.667 ms that needs a fixed
amount of work (2000 steps of a Python loop). A frame whose work ends after the next frame's
start is late. There is no affinity. EAS was switched at run time with `sched_energy_aware`,
using the method of section 1, all eight cores online, C2 on, schedutil free:

| Phase | EAS | Battery current | A53 busy (CPU-s) | A57 busy (CPU-s) | Mean A53 freq | Late frames |
|---|---|---|---|---|---|---|
| 1 | on | 165.4 mA | 238.9 | 7.2 | 444 MHz | 0 / 23206 |
| 2 | off | 163.5 mA | 103.9 | 38.2 | 448 MHz | 0 / 23280 |
| 3 | on | 177.2 mA | 239.1 | 6.9 | 438 MHz | 2 / 23086 |
| 4 | off | 141.3 mA | 53.7 | 50.6 | 451 MHz | 0 / 23333 |
| 5 | on | 179.5 mA | 237.9 | 7.3 | 443 MHz | 1 / 23226 |
| 6 | off | 158.0 mA | 90.0 | 42.3 | 448 MHz | 0 / 23175 |

Each phase lasts about 125 s, and "busy" is summed over the cluster's four CPUs. The A57s' mean
frequency was 804 MHz, their minimum, in every phase.

- **EAS on draws about 76 mW less** (the pairs: 7, 138, 82 mW). It keeps the work on the A53s,
  at about their lowest frequency for longer, and leaves the A57s in C2.
- The cost is 3 late frames in 69,518, against 0 in 69,788.
- More CPU-seconds (the A53s are slower), but less energy.

Heavy work, EAS on and off:

- One heavy single-threaded task (the Python loop, no affinity) ran on an A57 within 1 s in all
  runs: 2053 and 2317 ms with EAS, 2098 and 2066 ms without.
- Eight `xz -6` at once took 3270 ms with EAS and 3274 ms without. EAS steps aside when the
  system is overutilized.

**What it does not show.** The screen was dark. The load is synthetic, with no GPU and no
display work. Real interactive use was not measured.

## 6. Soak

Slot generation 21 (C2 from boot, EAS, `smp_exynos5433.hotplug=1`, `workqueue.power_efficient=1`),
2026-11-27, unattended, screen dark, on the Mac's USB.

Ten rounds of about 5.5 min each, 55 min in all. Each round:

1. 2 min of the UI-like load of section 5;
2. eight busy cores (four `xz -6` runs on each, no affinity);
3. the A57 cluster offline and back ten times, 0.5 s apart, as `t715-keys` does at each screen-off
   and wake;
4. 1 min idle with the A57s offline;
5. 2 min idle.

| | Result |
|---|---|
| Kernel warnings (`WARNING`, `BUG:`, `Oops`, `power-up timed out`, `SMP_FAILED`) | none |
| A57 offline/online writes refused | none in 100 cycles |
| CPUs online after each round | 0-7 |
| Late frames | 19 in 215,391 |
| Eight busy cores, four `xz` each | 13.0-13.6 s, mean 13.4 s, no drift |
| Hottest sensor after the busy part | 60 °C; 38-39 °C after the idle |
| C2 entries on CPUs 1-7 | about 1.06 million |
| Battery | 28 % to 32 %, charging |

After the soak, three suspends through the system's own path (`systemctl suspend` on the cable:
`t715-sleep-prepare` takes the radios down and arms nothing, so the kernel stops short of
`SMC_CMD_SLEEP`). All three passed (`suspend_stats` success 3, fail 0). The seven secondaries went
down and came back each time with no warning, and the Wi-Fi was connected again after each. A
reboot then came up with no warning and no failed unit.

What none of this covers: the screen lit, the GPU, a real sleep on battery.

## 7. schedutil's rate limit

The audit found these at idle, screen dark:

- the A53 policy changed frequency about 14 times a second, and the A57 policy about 1.7 times;
- each change sets the cluster's rail on the S2MPS13 PMIC over I2C (bus `i2c-23`,
  `14e40000.i2c`): about 350 I2C interrupts a second in total, about 23 per frequency change;
- the `sugov:0` kthread used about 1 % of a CPU.

The regmap of the S2MPS13 is cached (`REGCACHE_FLAT`), so these are writes. schedutil's
`rate_limit_us` (global: `/sys/devices/system/cpu/cpufreq/schedutil/rate_limit_us`) defaults to
1.5 × the transition latency: 186 µs (A53 latency 124 µs, A57 107 µs).

### The A/B of 186 µs against 2000 µs

The same load and method as section 5, EAS on, the limit switched at run time:

| Phase | rate_limit_us | Battery current | Mean A53 freq | Changes/s A53 + A57 | Late frames |
|---|---|---|---|---|---|
| 1 | 186 | 184.5 mA | 441 MHz | 44.5 + 7.6 | 4 / 23220 |
| 2 | 2000 | 163.0 mA | 451 MHz | 49.8 + 6.4 | 3 / 23102 |
| 3 | 186 | 192.2 mA | 437 MHz | 46.8 + 7.2 | 2 / 23045 |
| 4 | 2000 | 187.4 mA | 436 MHz | 43.2 + 7.9 | 1 / 23110 |
| 5 | 186 | 184.5 mA | 445 MHz | 46.3 + 9.9 | 2 / 23167 |
| 6 | 2000 | 169.7 mA | 440 MHz | 45.8 + 6.7 | 1 / 23098 |

- The limit changes nothing that matters. The policies changed frequency 43-50 times a second
  either way, far below the 500 a second a 2 ms limit allows. The changes follow the load's own
  bursts, not a limit too short.
- The power moved the other way from the one hoped for: the 2000 µs phases drew 52 mW more (pairs
  82, 18, 57 mW). Nothing in the counts explains it; it is at the edge of what three pairs
  resolve.
- **The default stays.** The I2C traffic to the PMIC is the price of following the load. It would
  shrink only with fewer voltage steps, for example OPPs that share a voltage; this chip's
  tables have one such pair (the A57 at 900 and 1000 MHz).

## 8. All of it together, against the daily kernel's behaviour

On slot generation 21, with run-time switches, by the method of section 1:

- **"Before"** is what the daily kernel of slot B does: C2 disabled on CPUs 1-7
  (`cpuidle/state1/disable`), `sched_energy_aware` 0, the A57 online.
- **"After"** is generation 21 as it runs: C2, EAS, and the A57 offline while the screen is dark.
  Under the load, the A57 stay online in both, as with the screen lit.
- `workqueue.power_efficient=1` is a boot-time switch, so it stays on in both.

| Case | Before | After | Pairs | After draws |
|---|---|---|---|---|
| Screen dark, idle | 203.1, 204.2, 184.3 mA | 216.5, 219.6, 239.1 mA | 52, 59, 211 mW | **about 108 mW less** |
| UI-like load (section 5), A57 online | 158.2, 171.0, 165.9 mA | 201.1, 189.7, 191.8 mA | 165, 72, 100 mW | **about 112 mW less** |

Under the load, 6 frames in 69,104 were late with everything on, against 0 in 69,557 without.

With the A57 offline, `sched_energy_aware` cannot be read: one cluster leaves no asymmetry, so
no EAS. When the A57 come back, it reads 1 again with both perf domains.

## 9. How to turn things off

- EAS: `echo 0 > /proc/sys/kernel/sched_energy_aware`.
- C2: `/sys/devices/system/cpu/cpuN/cpuidle/state1/disable`, or drop
  `cpuidle_exynos5433.enable=1`.
- The A57 hot-unplug: `smp_exynos5433.hotplug=0`.
- Back to the daily kernel of slot B: zero slot A's header, i.e. `dd` 512 bytes of zeros at
  sector 131072 of `/dev/mmcblk0p20`.
