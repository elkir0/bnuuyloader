# The secure monitor of the SM-T715 (Exynos 5433) and the `SMC 0x82000400` call on a secondary core

First version of 2026-11-24. Sections marked "(to be completed)" are not written yet.
Method: static disassembly of the boot partition image only (`../loader/dumps/mmcblk0boot0.bin`), plus S-Boot's own code.
Nothing was run on the tablet. No firmware bytes are reproduced: only addresses,
register values and logic.

Address conventions used below:

* **file offset**: offset inside `mmcblk0boot0.bin`.
* **monitor address**: where the code runs. The monitor image (file offsets `0x2000`..`0xd000`) is loaded at
  `0x02024000`, so `monitor address = 0x02022000 + file offset`. Its zero-filled data area runs on behind it.
* **S-Boot address**: `0x23DE2000 + file offset` (S-Boot is the `0x18000`..`0x9d000` region).

---

## 1. Where the monitor is

| Item | Value | How identified |
|---|---|---|
| Image | `mmcblk0boot0.bin`, file offsets `0x2000`..`0xd000` (44 KiB: 16-byte header, ~24 KiB code, data, strings) | strings at file `0xa6b0`..`0xaba0`: `Built : Jan 23 2017`, `UBL31 %s`, `mon_smc`, `tbase_smc`, `tbase_fastcall`, `tbase_oem_fastcall`, `tbase_cpu_on_finish_handler %d`, `PANIC in PC location 0x%016X`, and the names of every `_el3`/`_el1` register it dumps; build string `aarch64-linux-gnu-gcc (crosstool-NG linaro-1.13.1-4.8-2013.09)` |
| Architecture | **AArch64, EL3** (reads `mpidr_el1`, `scr_el3`, `cptr_el3`, sets `vbar_el3`) | disassembly is clean AArch64 (more than 99 % of the words decode, with `mrs/msr` of EL3 registers) and meaningless as ARM32 |
| Load address | `0x02024000` (iRAM) | BL1 (file `0x0`..`0x1c00`, AArch64) ends its warm path with `ldr w4, =0x02024010 ; br x4` (file `0x158`); the monitor stores `0x0202D000` in `VBAR_EL3` and that is exactly where its vector table sits in the image (file `0xb000`); its own function-pointer table holds `0x0202A9F0`, which is the start of the `0x82xx` SMC group handler (file `0x89f0`). All three agree on one base. |
| Entry | `0x02024010` | first instruction `mrs x1, cptr_el3` (file `0x2010`) |
| Vector table | `0x0202D000` (file `0xb000`), 16 vectors of 0x80 bytes, handlers at `0x0202D400+` | `msr vbar_el3, x0` at file `0x8974` |
| Reset entry of BL1 | file `0x10` | `b 0x18`, then checks, then either `br x5` (x5 = `*0x02020024`) or `br 0x02024010` |
| Data (zero-initialised) | `0x0202F000`.. about `0x02036600` | `adrp` targets up to file `0x15000` (= `0x02037000`) |

Confidence: **high** for image, architecture, entry and load address (three independent constants agree). The image is
not present in `mmcblk0boot1.bin`, `BOTA0`, `BOTA1` or `md5hdr.bin`.

Other contents of the boot partition, for orientation (all from strings):

* `0x00000`..`0x01c00`: BL1, AArch64, signed block `20140623 / SLSI / Exynos BL1` at `0x1bf8`.
* `0x02000`..`0x0d000`: the monitor (this document).
* `0x18000`..`0x09d000`: S-Boot, ARM32.
* `0x0ee000`..`0x0fd000`, `0x137000`..`0x14c000`: the Trustonic secure OS (`t-base-EXYNOS64-Android-302A-V015-681_681`).
* `0x16e000`..`0x175000`: the modem bootloader (`CL5311075`).
* `0x181000`..`0x199000`: an ARM32 component with the strings `Kernel Data Double Mapping`, `prevent_double_mapping`
  (Samsung's loadable firmware); it contains one `smc #0` (file `0x181028`) and the literal `0x82000401` (file `0x181034`).

**Runtime evidence missing:** the dump `iram-0x02020000-runtime.bin` does **not** contain the monitor (nor BL1) at the
addresses they are linked for: the 384 KiB are a dense ARM32 code blob with no strings except `ARMv7 Processor`, and
none of the monitor's bytes are found in it. It cannot be used to confirm the monitor's run-time state. See section 7.

## 2. How an SMC is dispatched

(to be completed)

## 3. The `0x82000400` handler

(to be completed)

## 4. Core dependence

(to be completed)

## 5. Secondary core power-on path

(to be completed)

## 6. Other calls

(to be completed)

## 7. Not determined

(to be completed)

## State on 2026-11-25

**Proven on the tablet.** Nothing was run for this reading. From the tablet, the monitor's call
`SMC 0x82000400` switches a secondary core to AArch64 at EL2, and that core reaches EL1 by an
`eret` (`SMP-EXPERIMENT.md` §7.2); the eight cores run the 64-bit kernel through the
enable-method built on that call (`SMP-EXPERIMENT.md` §8.4). This document has no run-time
confirmation of the load address of §1: the iRAM dump does not contain the monitor.

**Built or rehearsed only.** Nothing: the reading is static, and nothing was built or rehearsed
for it.

**Open.** Sections 2 to 7, each "(to be completed)": how an SMC is dispatched, the handler of
`0x82000400`, its core dependence, the secondary core power-on path, the other calls, and what
was not determined. The reading was begun on 2026-11-24 and not resumed.
