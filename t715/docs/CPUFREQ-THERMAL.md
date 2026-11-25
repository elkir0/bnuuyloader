# CPU frequency scaling and cooling on the arm64 kernel (stage 1)

Written 2026-11-24, after `smpk4` showed the four A57 at 1.2 GHz reaching 75 °C in 13 s of full load
on a kernel that could not slow a core down (`SMP-EXPERIMENT.md` §8.4).

## 1. Not an arm64 problem

The same thing happens on the 32-bit port: "At 1.2 GHz with four A57s loaded, atlas1 went from 71 to
85 °C in about 6 s" and "Four loaded A57s pass 81 °C within seconds even at 1.2 GHz" (the owner's
`omarchy-tab-s2/docs/hardware/CPUFREQ.md`, results of stage 2, 2026-11-07). The 32-bit daily
kernel answers it with cpufreq on this chip's tables and stock-like cooling maps; under an 8-core stress
of 45 minutes they held atlas1 at 91-97 °C with the A57 around 1.0 GHz (the soak of 2026-11-07). The
arm64 kernel needed the same, and nothing else: the board's device tree already carries it all.

## 2. What the arm64 board's device tree already holds

From the arm64 DTB of the kernel tree (the board of patch 0003, built from the release tree's board):

| | |
|---|---|
| A53 table (`opp-table-t715-a53`, all eight CPUs of the cluster) | 400 875 · 500 912.5 · 600 937.5 · 800 1000 · 900 1025 · 1000 1087.5 · 1100 1125 · **1200 1162.5** (suspend) MHz · mV |
| A57 table (`opp-table-t715-a57`) | 800 987.5 · 900 1012.5 · 1000 1012.5 · 1100 1037.5 · **1200 1062.5** (suspend) · 1300 1125 · 1400 1150 · 1500 1175 MHz · mV |
| `cpu-supply` | on cpu0 (BUCK3, `vdd_kfc`, 875-1162.5 mV) and cpu4 (BUCK2, `vdd_eagle`, 987.5-1175 mV) |
| atlas0, atlas1 passive trips | 81 °C: A57 states 0-3 (down to 1.2 GHz); 95 °C: A57 3-6 (0.9 GHz), A53 0-2 (1.0 GHz); 100 °C: A57 6-7 (0.8 GHz), A53 2-7 (0.4 GHz) |
| apollo passive trips | 81 °C: A53 0-2, A57 3-6; 86 °C: A53 2-7, A57 6-7 |
| critical | 115 °C on every zone (hardware protection shutdown) |
| `atlas-asv@11810000` | A57 body bias level 8, EMA 3 (the vendor kernel's values) |

These are the owner's 32-bit daily values (`CPUFREQ.md` §4, §5.2, decisions D3 and D7), the voltages
this chip's own (ASV group 1). The trap of `CPUFREQ.md` §2.3 (a table without `cpu-supply`: the clock
moves, the rail does not) does not apply: both supplies are there, and the steps below check the rail.

## 3. The test kernel

`../kernel/smp/build-kernel.sh --thermal` (`Image-thermal`): the eight-core test kernel plus `CPU_FREQ`,
`CPU_FREQ_STAT`, `CPUFREQ_DT` (built in: this kernel loads no module), `CPU_FREQ_DEFAULT_GOV_USERSPACE`
(the driver changes nothing when it probes), `schedutil` and `performance`, `CPU_THERMAL`,
`CPU_FREQ_THERMAL`, `THERMAL_EMULATION`, `EXYNOS5433_ATLAS_ASV`, the hang detectors; still no cpuidle,
no PM. Patch 0005 (`../kernel/smp/`) silences a warning of the arm64 topology code that has no
architected timer frequency to work with on this boot path (§5).

The test init (`../kernel/test-kernel/init.c`, `t715.cpufreq=1`), after the readouts:
1. **Stage 1 cap**: `scaling_max_freq` = 1.2 GHz on both policies, read back (waiting for the QoS work
   item), before any governor but `userspace` runs. Nothing above 1.2 GHz is ever used.
2. **Steps**, each cluster at three levels, low to high: the clock as the clock driver reads it
   (`cpuinfo_cur_freq`), the rail against this chip's OPP, a hash (100 rounds over 2 MiB) on each core
   of the cluster compared with the one cpu0 computed at the boot clock.
3. **Storms**: 4 s of flips every 50 ms between the lowest and the highest level, the cluster hashing.
4. **Emulated temperatures** (`emul_temp`): atlas1 101 °C and apollo 87 °C, then the release.
5. **Rest** under `schedutil`, 8 s.
6. **Load**: eight hashing processes for 40 s under `performance`, with the passive trips of the test
   lowered (atlas 95 → 68 °C and 100 → 75 °C; apollo 81 → 68 °C and 86 → 75 °C, restored afterwards)
   so that the cooling acts well below the project's 85 °C limit; stop at 85 °C.
Any wrong clock, rail or hash ends the test at once; the clusters go back to 1.2 GHz before the restart.

## 4. On the tablet

| cycle | date | PARAM sha256 | result |
|---|---|---|---|
| `cpuf1` | 2026-11-24 | `6245a382…` | every check ok; one `WARNING` at boot (§5) |
| `cpuf2` | 2026-11-24 | `c04270fb…` | no warning; the test stopped itself at "the 1.2 GHz cap could not be set": the init read `scaling_max_freq` back before the QoS work item had applied it (a race of the test, fixed) |
| `cpuf3` | 2026-11-24 | `c6f7d8a8…` | **every check ok, no warning, no oops, no stall** |

Each cycle came back under the 32-bit system by itself, the original PARAM restored and verified.

What `cpuf3` (and `cpuf1`) show, from the kernel's log (the pstore records of `cpuf3`):

- `atlas-asv`: `A57 body bias: BB_CON0 0x80000088 -> 0x80000088` (already so at the handoff),
  `cpu4 online: EMA 0x00210210 -> 0x00310310`: the vendor kernel's state, as on the 32-bit daily.
- Every passive trip bound to the cooling devices the maps name (`cpufreq-cpu0`, `cpufreq-cpu4`).
- Steps (`cpuf3`):

  | cluster | kHz | clock read | rail uV (OPP) | hashes | s |
  |---|---|---|---|---|---|
  | A53 | 400 000 | 400 000 | 875 000 (875 000) | 4/4 | 6.43 |
  | A53 | 800 000 | 800 000 | 1 000 000 (1 000 000) | 4/4 | 5.38 |
  | A53 | 1 200 000 | 1 200 000 | 1 162 500 (1 162 500) | 4/4 | 4.89 |
  | A57 | 800 000 | 800 000 | 987 500 (987 500) | 4/4 | 1.54 |
  | A57 | 1 000 000 | 1 000 000 | 1 012 500 (1 012 500) | 4/4 | 1.53 |
  | A57 | 1 200 000 | 1 200 000 | 1 062 500 (1 062 500) | 4/4 | 1.34 |

  (the A53 hash time is memory-bound at the higher levels: the 2 MiB buffer is larger than their L2)
- Storms: A57 800 ↔ 1200 MHz, 42 transitions, 148 hashes, 0 wrong; A53 400 ↔ 1200 MHz, 42
  transitions, 32 hashes, 0 wrong.
- Emulation: atlas1 at 101 °C and apollo at 87 °C each gave A53 1.0 GHz (state 2) and A57 0.9 GHz
  (state 6), as the maps say; both released to 1.2 GHz (state 0).
- Rest under `schedutil`: A53 at 400 MHz and 875 mV, A57 at 800 MHz and 987.5 mV (against 1.1625 V and
  1.0625 V at the fixed 1.2 GHz); the zones went from 49 to 46 °C in 8 s.
- **Load, eight cores, 40 s, cooling acting** (`cpuf1`, from 56 °C):

  | t | atlas0 / atlas1 / apollo °C | A53 MHz (state) | A57 MHz (state) |
  |---|---|---|---|
  | 1 s | 56 / 59 / 49 | 1200 (0) | 1200 (0) |
  | 6 s | 65 / 68 / 57 | 1100 (1) | 1200 (3) |
  | 12 s | 65 / 68 / 59 | 1000 (2) | 1000 (5) |
  | 23 s | 67 / 69 / 60 | 1000 (2) | 900 (6) |
  | 40 s | 69 / 71 / 62 | 1000 (2) | 900 (6) |

  1360 hashes, 0 wrong; hottest 71 °C. In `cpuf3` (from 59 °C): the same steps, 74 °C at 40 s, 1363
  hashes, 0 wrong. Against `smpk4` (no cooling): 75 °C after 13 s and rising 0.8 °C a second; here the
  rise is about 0.15 °C a second once the clusters are at 0.9 / 1.0 GHz, and the next trip (75 °C: A57
  0.8 GHz, A53 down to 0.4 GHz) was about to act.

**Proven:** on the arm64 kernel, cpufreq-dt drives both clusters on this chip's own table with the
right voltage at every level used; transitions under load are clean; the cooling maps bind and cap as
they say; under a real eight-core load the cooling takes the clusters down step by step and the
temperature levels off. **Not done:** levels above 1.2 GHz (stage 2 of `CPUFREQ.md`; the 32-bit port
validated them, the arm64 one has not run them), the daily trips under a long load (the 32-bit soak
held 91-97 °C), a long soak, `schedutil` under a real workload.

## 5. The warning of `cpuf1`

`WARNING: CPU: 2 PID: 55 at arch/arm64/kernel/topology.c:125 freq_inv_set_max_ratio+0x4c/0xb8`, when
the first policy registered. `freq_inv_set_max_ratio()` takes `arch_timer_get_rate()` as the reference
of the activity monitors' frequency invariance; on this boot path the generic counter does not run
(`CNTFRQ` = 0, the reason for the MCT patch), so the reference is 0 and it warned. These cores have no
AMU, so nothing was lost; cpufreq's own invariance applies. Patch 0005 (commit 5712afc8c on
`t715-arm64-smp`) returns quietly when the reference is 0 and keeps the warning for a maximum of 0.
`cpuf3` has no warning.

## 6. What the daily arm64 system should take

**Decided by the owner, 2026-11-24: like the 32-bit daily.** The daily arm64
system keeps the board's maps as they are: 81/95/100 °C on the A57 sensors (atlas0, atlas1), 81/86 °C
on the A53's (apollo), 115 °C critical, with `schedutil`; the A57 cap at 1.2 GHz until stage 2 has run
on arm64, then 1.5 GHz as on the 32-bit daily. Under a long full load that means about 95 °C at about
1.0 GHz, as there (the 32-bit soak held atlas1 at 91-97 °C). Nothing in the device tree changes for
it: those are the trips of the arm64 board as built (§2). The 68/75 °C trips exist only inside the
test init, for the length of its load, and are restored afterwards.

The cooler alternative that was offered (68/75 °C for the daily system) was not taken.
## State on 2026-11-25

**Proven on the tablet.** Stage 1 is in the full kernel that booted on the tablet with a root image
on 2026-11-25 (the release configuration translated to arm64, the eight-core method, the initramfs
built in): cpufreq on this chip's own tables with their rails, the cooling maps, the A57 at 1.2 GHz
at most, and the trips as the owner chose, those of the 32-bit daily (81/95/100 °C, 81/86 °C),
unchanged in the device tree. The arm64 system replaces the 32-bit one (the owner's decision,
2026-11-24); cold boot by the power key reaches user space in 12 s. Of what §4 lists as not done,
the long soak under the daily trips has run: several hours with twelve 3-min phases of eight busy
cores, atlas peak 94 °C, cooling to 0.9/1.0 GHz, no reboot, the watchdog keeper and Wi-Fi in every
sample.

**Built or rehearsed only.** The A57 levels above 1.2 GHz are in the board's table (§2) and have
not run on arm64: the 32-bit port validated them; the cap stays at 1.2 GHz until stage 2 has run
here.

**Open.** Stage 2 on arm64 (the A57 above 1.2 GHz: the same protocol, with the owner present);
`schedutil` under real use; idle power; the battery heat guard of the 32-bit port; charging on a
wall charger (the driver gives it 1750 mA; the port of the owner's computer gets 450 mA, less than
eight busy cores and the screen draw).
