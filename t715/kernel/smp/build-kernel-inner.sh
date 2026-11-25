#!/bin/bash
# Runs inside the t715-kbuild container (smp/build-kernel.sh): $1 is the kernel tree (read-only),
# $SMP_O the build directory (in the Docker volume of this work stream), /work this directory.
# See build-kernel.sh.
set -euo pipefail
cd "$1"
JOBS="${SMP_JOBS:-8}"
CONFIGURATION="${SMP_CONFIGURATION:-boot}"
O="${SMP_O:-/build/out}"
OUT=/work
mkdir -p "$O" "$OUT"
LOG="$OUT/build-$CONFIGURATION.log"
: > "$LOG"
note() { echo ">>> $*" | tee -a "$LOG"; }

note "configuration ($CONFIGURATION): tree $1, output $O"
make ARCH=arm64 O="$O" allnoconfig >/dev/null 2>&1
C="$1/scripts/config --file $O/.config"
# --- what a kernel needs to run one static program and to be read afterwards
for o in EXPERT PRINTK BUG ELF BINFMT_ELF KALLSYMS MAGIC_SYSRQ MULTIUSER FUTEX SHMEM PROC_FS SYSFS TMPFS DEVTMPFS DEVTMPFS_MOUNT \
         DEBUG_FS PANIC_TIMEOUT BLK_DEV_INITRD RD_GZIP MISC_FILESYSTEMS; do $C -e "$o"; done
# --- the SoC, as little of it as a first start needs
$C -e ARCH_EXYNOS
# --- what must work: the kernel log in the RAM ring, a crash log, the watchdog, the restart, heat protection
for o in SAMSUNG_SEC_LOG_CONSOLE PSTORE PSTORE_CONSOLE PSTORE_RAM WATCHDOG S3C2410_WATCHDOG WATCHDOG_SYSFS \
         POWER_RESET POWER_RESET_SYSCON THERMAL THERMAL_OF THERMAL_DEFAULT_GOV_STEP_WISE EXYNOS_THERMAL COMMON_CLK_DEBUG; do $C -e "$o"; done
# --- the PMIC (S2MPS13 on HSI2C channel 0), to read its rails only
for o in I2C I2C_EXYNOS5 MFD_SEC_CORE REGULATOR REGULATOR_S2MPS11; do $C -e "$o"; done
# --- nothing that changes a frequency, a voltage, a bias, a power domain, or touches a peripheral
for o in CPU_FREQ CPU_IDLE PM PM_DEVFREQ PM_GENERIC_DOMAINS EXYNOS_PM_DOMAINS SUSPEND COMPAT \
         EXYNOS5433_ATLAS_ASV EXYNOS5433_G3D_ABB EXYNOS_REGULATOR_COUPLER EXYNOS_ASV_ARM REGULATOR_FIXED \
         DRM PANFROST USB PCI NET MMC SOUND INPUT TOUCHSCREEN SERIAL_8250 EXYNOS_IOMMU GPIO_SYSFS \
         RTC_CLASS COMMON_CLK_S2MPS11 VIRTUALIZATION KVM SECURITY LOCKDEP FUNCTION_TRACER; do $C -d "$o"; done
$C -d CMDLINE_FORCE -d CMDLINE_EXTEND -e CMDLINE_FROM_BOOTLOADER --set-str CMDLINE ""
$C -e CC_OPTIMIZE_FOR_SIZE -d CC_OPTIMIZE_NO_AUTO_INLINE
$C --set-val PANIC_TIMEOUT 5 -e ARM64_VA_BITS_39 -d ARM64_VA_BITS_48 -d ARM64_VA_BITS_52 --set-val NR_CPUS 8
for o in EXYNOS_AUDSS_CLK_CON EXYNOS_CLKOUT EXYNOS_USI; do $C -d "$o"; done
# --- this work stream: the method, and hot-unplug compiled in (the method refuses it at run time)
$C -e HOTPLUG_CPU -e ARM64_EXYNOS5433_SMP
# --- the configuration asked for the compile test has PM
[ "$CONFIGURATION" = requested ] && $C -e PM
# --- "thermal": the boot configuration plus CPU frequency scaling and CPU cooling, as the 32-bit daily
#     kernel has them (owner's docs/hardware/CPUFREQ.md 2.1): cpufreq-dt on the board's own tables
#     (with their cpu-supply), the userspace governor by default (the driver changes nothing when it
#     probes), schedutil and performance, CPU cooling devices, temperature emulation for the throttle
#     test, the A57 body bias and EMA as the vendor kernel sets them (exynos5433-atlas-asv), and the
#     owner's hang detectors for test kernels.  cpufreq-dt is built in: this kernel loads no module.
if [ "$CONFIGURATION" = thermal ]; then
    for o in CPU_FREQ CPU_FREQ_STAT CPUFREQ_DT CPUFREQ_DT_PLATDEV CPU_FREQ_GOV_USERSPACE CPU_FREQ_GOV_PERFORMANCE \
             CPU_FREQ_GOV_SCHEDUTIL CPU_FREQ_DEFAULT_GOV_USERSPACE CPU_THERMAL CPU_FREQ_THERMAL THERMAL_EMULATION \
             EXYNOS5433_ATLAS_ASV DETECT_HUNG_TASK SOFTLOCKUP_DETECTOR; do $C -e "$o"; done
    $C -d CPU_FREQ_DEFAULT_GOV_PERFORMANCE -d CPU_FREQ_DEFAULT_GOV_SCHEDUTIL -d CPU_IDLE
fi
make ARCH=arm64 O="$O" olddefconfig >/dev/null 2>&1
cp "$O/.config" "$OUT/config-$CONFIGURATION"

note "configuration checks"
missing=0
for s in ARCH_EXYNOS COMMON_CLK_SAMSUNG EXYNOS_ARM64_COMMON_CLK PINCTRL_EXYNOS PINCTRL_EXYNOS_ARM64 EXYNOS_PMU \
         SAMSUNG_SEC_LOG_CONSOLE PSTORE PSTORE_RAM PSTORE_CONSOLE S3C2410_WATCHDOG POWER_RESET_SYSCON THERMAL_OF THERMAL \
         EXYNOS_THERMAL MFD_SEC_CORE REGULATOR_S2MPS11 I2C_EXYNOS5 PROC_FS SYSFS DEVTMPFS DEVTMPFS_MOUNT MAGIC_SYSRQ \
         ARM_ARCH_TIMER CLKSRC_EXYNOS_MCT ARM_GIC DEBUG_FS BINFMT_ELF BLK_DEV_INITRD SMP HOTPLUG_CPU ARM64_EXYNOS5433_SMP; do
    grep -q "^CONFIG_$s=y" "$O/.config" || { echo "MISSING: CONFIG_$s" | tee -a "$LOG"; missing=1; }
done
if [ "$CONFIGURATION" = thermal ]; then
    for s in CPU_FREQ CPU_FREQ_STAT CPUFREQ_DT CPU_FREQ_DEFAULT_GOV_USERSPACE CPU_FREQ_GOV_SCHEDUTIL CPU_FREQ_GOV_PERFORMANCE \
             CPU_THERMAL CPU_FREQ_THERMAL THERMAL_EMULATION EXYNOS5433_ATLAS_ASV; do
        grep -q "^CONFIG_$s=y" "$O/.config" || { echo "MISSING: CONFIG_$s" | tee -a "$LOG"; missing=1; }
    done
    for s in CPU_IDLE PM PM_DEVFREQ PM_GENERIC_DOMAINS EXYNOS_PM_DOMAINS SUSPEND EXYNOS5433_G3D_ABB DRM USB PCI NET MMC SOUND; do
        if grep -q "^CONFIG_$s=" "$O/.config"; then echo "UNWANTED: CONFIG_$s is set" | tee -a "$LOG"; missing=1; fi
    done
fi
if [ "$CONFIGURATION" = boot ]; then
    for s in CPU_FREQ CPU_IDLE PM PM_DEVFREQ PM_GENERIC_DOMAINS EXYNOS_PM_DOMAINS SUSPEND COMPAT EXYNOS5433_ATLAS_ASV EXYNOS5433_G3D_ABB \
             EXYNOS_REGULATOR_COUPLER EXYNOS_ASV_ARM REGULATOR_FIXED DRM USB PCI NET MMC SOUND SERIAL_8250 EXYNOS_IOMMU; do
        if grep -q "^CONFIG_$s=" "$O/.config"; then echo "UNWANTED: CONFIG_$s is set" | tee -a "$LOG"; missing=1; fi
    done
    for s in RANDOMIZE_BASE ARM64_VA_BITS_52; do
        grep -q "^CONFIG_$s=" "$O/.config" && { echo "UNWANTED: CONFIG_$s is set" | tee -a "$LOG"; missing=1; }
    done
fi
grep -E "^CONFIG_(CMDLINE|PANIC_TIMEOUT|ARM64_VA_BITS|NR_CPUS|SMP|HOTPLUG_CPU|ARM64_EXYNOS5433_SMP|PM|PM_GENERIC_DOMAINS|EXYNOS_PM_DOMAINS|RANDOMIZE_BASE|ARCH_EXYNOS|DEBUG_INFO|STRICT_KERNEL_RWX|HOTPLUG_PARALLEL)=" "$O/.config" | tee -a "$LOG"
[ "$missing" = 0 ] || { echo "the configuration is not as wanted" | tee -a "$LOG"; exit 1; }
grep -q "architected timer absent" "$1/arch/arm64/kernel/time.c" || { echo "the owner's MCT patch is not in place" | tee -a "$LOG"; exit 1; }

if [ -f /test-kernel/init.c ]; then
    note "the owner's test init"
    gcc -static -O2 -Wall -Wextra -o "$OUT/init" /test-kernel/init.c 2>&1 | tee -a "$LOG"
    cat > "$OUT/initramfs.list" <<LIST
dir /init 0755 0 0
file /init $OUT/init 0755 0 0
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/kmsg 0644 0 0 c 1 11
dir /proc 0555 0 0
dir /sys 0555 0 0
dir /tmp 01777 0 0
LIST
    INITRAMFS="CONFIG_INITRAMFS_SOURCE=$OUT/initramfs.list CONFIG_INITRAMFS_COMPRESSION_GZIP=y"
else
    note "no test init: an Image without one (for compiling only)"
    INITRAMFS=""
fi

note "kernel"
status=0
KBUILD_BUILD_TIMESTAMP="Sat Nov 21 12:00:00 UTC 2026" KBUILD_BUILD_USER=t715-arm64-test KBUILD_BUILD_HOST=loader KBUILD_BUILD_VERSION=1 \
    make ARCH=arm64 O="$O" -j"$JOBS" $INITRAMFS Image >> "$LOG" 2>&1 || status=$?
{ grep -n -B2 -A8 "error:\|Error \|warning:.*smp_exynos5433\|undefined" "$LOG" || true; } | head -n 80
tail -n 4 "$LOG"
[ "$status" = 0 ] || { echo "the kernel did not build: see $LOG"; exit "$status"; }
cp "$O/arch/arm64/boot/Image" "$OUT/Image-$CONFIGURATION"
cp "$O/System.map" "$OUT/System.map-$CONFIGURATION"

note "device tree"
make ARCH=arm64 O="$O" -j"$JOBS" exynos/exynos5433-gts28ltexx.dtb >> "$LOG" 2>&1 || { tail -n 30 "$LOG"; exit 1; }
DTB="$OUT/exynos5433-gts28ltexx-arm64-$CONFIGURATION.dtb"
cp "$O/arch/arm64/boot/dts/exynos/exynos5433-gts28ltexx.dtb" "$DTB"
"$O/scripts/dtc/dtc" -I dtb -O dts "$DTB" 2>/dev/null > "${DTB%.dtb}.dts"
{
    grep -n "enable-method\|psci" "${DTB%.dtb}.dts" | grep -v "phandle"
    echo "cpu nodes with the method: $(grep -c 'enable-method = "samsung,exynos5433-el2"' "${DTB%.dtb}.dts") (8 wanted); lines mentioning psci: $(grep -c 'psci' "${DTB%.dtb}.dts") (0 wanted)"
} | tee -a "$LOG"
[ "$(grep -c 'enable-method = "samsung,exynos5433-el2"' "${DTB%.dtb}.dts")" = 8 ] && [ "$(grep -c 'psci' "${DTB%.dtb}.dts")" = 0 ] || { echo "the device tree is not as wanted" | tee -a "$LOG"; exit 1; }

note "the stubs in vmlinux"
python3 - "$O" <<'PY' | tee -a "$LOG"
import subprocess, sys, re

O = sys.argv[1]
nm = subprocess.run(["nm", "-n", O + "/vmlinux"], capture_output=True, text=True, check=True).stdout
syms = {}
for line in nm.splitlines():
    p = line.split()
    if len(p) == 3:
        syms[p[2]] = int(p[0], 16)
print("    symbols (link addresses):")
for n in ("_text", "exynos5433_smp_entry", "exynos5433_smp_entry_el2", "exynos5433_smp_pen",
          "exynos5433_smp_pen_release", "__mmuoff_data_start", "__mmuoff_data_end",
          "secondary_entry", "exynos5433_smp_ops"):
    print(f"      {n:30s} {syms[n]:#018x}" if n in syms else f"      {n:30s} MISSING")

e, el2, pen, rel = (syms["exynos5433_smp_entry"], syms["exynos5433_smp_entry_el2"],
                    syms["exynos5433_smp_pen"], syms["exynos5433_smp_pen_release"])
ok = True
def check(cond, what):
    global ok
    print(("    ok   " if cond else "    FAIL ") + what)
    ok = ok and cond

# The words of the AArch32 stub: read from the section of vmlinux that holds it.
# where does .text start in the file image? objdump gives the section's address and file position
sections = subprocess.run(["readelf", "-S", "-W", O + "/vmlinux"], capture_output=True, text=True, check=True).stdout
text = re.search(r"\[\s*\d+\]\s+\.text\s+\w+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)", sections)
addr, off = int(text.group(1), 16), int(text.group(2), 16)
at = off + (e - addr)
with open(O + "/vmlinux", "rb") as f:
    f.seek(at)
    data = f.read(48)
words = [int.from_bytes(data[4 * i:4 * i + 4], "little") for i in range(12)]
print("    AArch32 stub, as it stands in vmlinux: " + " ".join(f"{w:08x}" for w in words))
check(words == [0xf10c01c0, 0xe59f1020, 0xe081100f, 0xe3000400, 0xe3480200, 0xe3a02b02, 0xe3a03001, 0xf57ff04f, 0xe1600070, 0xe320f002, 0xeafffffd, 0x000007f0],
      "the words are those of the source in the comment (as clang assembles it for arm-none-eabi)")
check(e % 2048 == 0 and el2 % 2048 == 0, f"both entries are on a 2 KiB boundary ({e:#x}, {el2:#x})")
check(el2 - e == 2048, f"the entries are 2 KiB apart ({el2 - e})")
check(words[11] == el2 - e - 16, f"the constant of the AArch32 stub is the distance to the AArch64 entry ({words[11]} = {el2 - e - 16})")
check(syms["__mmuoff_data_start"] <= rel < syms["__mmuoff_data_end"], "the pen is in .mmuoff.data (read with the MMU off)")
check(rel % 8 == 0, "the pen is 8-byte aligned")
check(e - syms["_text"] < 2**32 and el2 - syms["_text"] < 2**32, "both entries are below 4 GiB from the start of the kernel image")

def dump(a, b, title):
    print(f"    == {title}")
    d = subprocess.run(["objdump", "-d", "--no-show-raw-insn", f"--start-address={a:#x}", f"--stop-address={b:#x}", O + "/vmlinux"],
                       capture_output=True, text=True).stdout
    for line in d.splitlines()[7:]:
        if line.strip():
            print("       " + line.strip())
dump(el2, pen, "exynos5433_smp_entry_el2 (AArch64, entered at EL2)")
after = min(a for a in syms.values() if a > pen)
dump(pen, after, "exynos5433_smp_pen (AArch64, entered at EL1)")
sys.exit(0 if ok else 1)
PY
[ "${PIPESTATUS[0]}" = 0 ] || { echo "the stubs are not as wanted" | tee -a "$LOG"; exit 1; }

cd "$OUT" && ls -la "Image-$CONFIGURATION" "config-$CONFIGURATION" "$DTB" "${DTB%.dtb}.dts" 2>/dev/null
sha256sum "Image-$CONFIGURATION" "$DTB" | tee -a "$LOG"
echo "Image-$CONFIGURATION: $(stat -c %s "Image-$CONFIGURATION") bytes" | tee -a "$LOG"
note "done"
