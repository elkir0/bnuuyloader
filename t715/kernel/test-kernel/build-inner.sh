#!/bin/bash
# Runs inside the t715-kbuild container: /src is the release tree (read-only) with the files of
# overlay/ mounted over it, /work this directory, /build a Docker volume of its own. Builds the minimal arm64 kernel for the first
# boot test, with the test init built in, and the tablet's device tree with the boot arguments.
set -euo pipefail
cd /src
JOBS="${JOBS:-8}"
OUT=/work/out
mkdir -p "$OUT"

echo ">>> init"
gcc -static -O2 -Wall -Wextra -o "$OUT/init" /work/init.c
ls -la "$OUT/init"
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

echo ">>> configuration"
make ARCH=arm64 O=/build allnoconfig >/dev/null
C="/src/scripts/config --file /build/.config"
# --- what a kernel needs to run one static program and to be read afterwards
for o in EXPERT PRINTK BUG ELF BINFMT_ELF KALLSYMS MAGIC_SYSRQ MULTIUSER FUTEX SHMEM PROC_FS SYSFS TMPFS DEVTMPFS DEVTMPFS_MOUNT \
         DEBUG_FS PANIC_TIMEOUT BLK_DEV_INITRD RD_GZIP MISC_FILESYSTEMS; do $C -e "$o"; done
# --- the SoC, as little of it as a first start needs: clocks, interrupts, timers, the PMU, pinctrl
$C -e ARCH_EXYNOS
# --- what must work: the kernel log in the RAM ring, a crash log, the watchdog, the restart, heat protection
for o in SAMSUNG_SEC_LOG_CONSOLE PSTORE PSTORE_CONSOLE PSTORE_RAM WATCHDOG S3C2410_WATCHDOG WATCHDOG_SYSFS \
         POWER_RESET POWER_RESET_SYSCON THERMAL THERMAL_OF THERMAL_DEFAULT_GOV_STEP_WISE EXYNOS_THERMAL COMMON_CLK_DEBUG; do $C -e "$o"; done
# --- the PMIC (an S2MPS13 on HSI2C channel 0), only so that its rails can be read: nothing may set a
#     voltage (every buck is always on, boot on, in a range that holds what S-Boot left)
for o in I2C I2C_EXYNOS5 MFD_SEC_CORE REGULATOR REGULATOR_S2MPS11; do $C -e "$o"; done
# --- nothing that changes a frequency, a voltage, a bias, a power domain, or touches a peripheral
for o in SMP CPU_FREQ CPU_IDLE PM PM_DEVFREQ PM_GENERIC_DOMAINS EXYNOS_PM_DOMAINS SUSPEND COMPAT \
         EXYNOS5433_ATLAS_ASV EXYNOS5433_G3D_ABB EXYNOS_REGULATOR_COUPLER EXYNOS_ASV_ARM REGULATOR_FIXED \
         DRM PANFROST USB PCI NET MMC SOUND INPUT TOUCHSCREEN SERIAL_8250 EXYNOS_IOMMU GPIO_SYSFS \
         RTC_CLASS COMMON_CLK_S2MPS11 VIRTUALIZATION KVM SECURITY LOCKDEP FUNCTION_TRACER; do $C -d "$o"; done
$C -d CMDLINE_FORCE -d CMDLINE_EXTEND -e CMDLINE_FROM_BOOTLOADER --set-str CMDLINE ""
# --- small: the kernel is stored inside PARAM, between the end of its archive and S-Boot's own data
$C -e CC_OPTIMIZE_FOR_SIZE -d CC_OPTIMIZE_NO_AUTO_INLINE
$C --set-val PANIC_TIMEOUT 5 -e ARM64_VA_BITS_39 -d ARM64_VA_BITS_48 -d ARM64_VA_BITS_52 --set-val NR_CPUS 8
for o in EXYNOS_AUDSS_CLK_CON EXYNOS_CLKOUT EXYNOS_USI; do $C -d "$o"; done
make ARCH=arm64 O=/build olddefconfig >/dev/null

echo ">>> configuration checks"
missing=0
for s in ARCH_EXYNOS COMMON_CLK_SAMSUNG EXYNOS_ARM64_COMMON_CLK PINCTRL_EXYNOS PINCTRL_EXYNOS_ARM64 EXYNOS_PMU \
         SAMSUNG_SEC_LOG_CONSOLE PSTORE PSTORE_RAM PSTORE_CONSOLE S3C2410_WATCHDOG POWER_RESET_SYSCON THERMAL_OF THERMAL \
         EXYNOS_THERMAL MFD_SEC_CORE REGULATOR_S2MPS11 I2C_EXYNOS5 PROC_FS SYSFS DEVTMPFS DEVTMPFS_MOUNT MAGIC_SYSRQ \
         ARM_ARCH_TIMER CLKSRC_EXYNOS_MCT ARM_GIC DEBUG_FS BINFMT_ELF BLK_DEV_INITRD; do
    grep -q "^CONFIG_$s=y" /build/.config || { echo "MISSING: CONFIG_$s"; missing=1; }
done
for s in CPU_FREQ CPU_IDLE PM_DEVFREQ PM_GENERIC_DOMAINS EXYNOS_PM_DOMAINS SUSPEND COMPAT EXYNOS5433_ATLAS_ASV EXYNOS5433_G3D_ABB \
         EXYNOS_REGULATOR_COUPLER EXYNOS_ASV_ARM REGULATOR_FIXED DRM USB PCI NET MMC SOUND SERIAL_8250 EXYNOS_IOMMU; do
    if grep -q "^CONFIG_$s=" /build/.config; then echo "UNWANTED: CONFIG_$s is set"; missing=1; fi
done
grep -E "^CONFIG_(CMDLINE|PANIC_TIMEOUT|ARM64_VA_BITS|ARM64_4K_PAGES|NR_CPUS|EXYNOS_MCT|GIC_NON_BANKED|PM_GENERIC_DOMAINS|CLK_IGNORE_UNUSED|PINCTRL_EXYNOS|CC_OPTIMIZE_FOR_SIZE|SMP|ARM_ARCH_TIMER|RANDOMIZE_BASE|GENERIC_CALIBRATE_DELAY|HZ|WATCHDOG_NOWAYOUT|STRICT_DEVMEM|KALLSYMS)" /build/.config
# (SMP cannot be switched off on arm64: it is def_bool y; the boot arguments keep every other core off with nosmp)
for s in RANDOMIZE_BASE ARM64_VA_BITS_52; do
    grep -q "^CONFIG_$s=" /build/.config && { echo "UNWANTED: CONFIG_$s is set"; missing=1; }
done
[ "$missing" = 0 ] || exit 1
grep -c "architected timer absent" /src/arch/arm64/kernel/time.c || exit 1

echo ">>> kernel"
status=0
KBUILD_BUILD_TIMESTAMP="Sat Nov 21 12:00:00 UTC 2026" KBUILD_BUILD_USER=t715-arm64-test KBUILD_BUILD_HOST=loader KBUILD_BUILD_VERSION=1 \
    make ARCH=arm64 O=/build -j"$JOBS" CONFIG_INITRAMFS_SOURCE="$OUT/initramfs.list" CONFIG_INITRAMFS_COMPRESSION_GZIP=y Image > "$OUT/make.log" 2>&1 || status=$?
{ grep -n -B2 -A6 "error:\|Error " "$OUT/make.log" || true; } | head -n 60
tail -n 6 "$OUT/make.log"
[ "$status" = 0 ] || exit "$status"
cp /build/arch/arm64/boot/Image "$OUT/Image"
echo ">>> what the Image holds (largest symbols)"
nm -S --size-sort /build/vmlinux 2>/dev/null | tail -n 25 | while read -r address size type name; do printf '%10d  %s %s\n' "$((16#$size))" "$type" "$name"; done
ls -la /build/usr/initramfs_data.cpio /build/usr/initramfs_inc_data 2>/dev/null | awk '{print $5, $9}'
[ "$(stat -c %s /build/usr/initramfs_inc_data)" -lt "$(stat -c %s /build/usr/initramfs_data.cpio)" ] || { echo "the initramfs is not compressed"; exit 1; }
echo "Image: $(stat -c %s "$OUT/Image") bytes; the room in PARAM is $((0x700000 - 0x120000)) for it and the device tree"

echo ">>> device tree"
make ARCH=arm64 O=/build -j"$JOBS" scripts/dtc/ >/dev/null 2>&1
cpp -nostdinc -I/src/scripts/dtc/include-prefixes -undef -D__DTS__ -x assembler-with-cpp \
    /src/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts | /build/scripts/dtc/dtc -O dtb -o "$OUT/gts28ltexx-base.dtb" -b 0 2>/dev/null
cpp -nostdinc -I/src/scripts/dtc/include-prefixes -undef -D__DTS__ -x assembler-with-cpp \
    /work/bootargs.overlay.dts | /build/scripts/dtc/dtc -O dtb -o "$OUT/bootargs.dtbo" -b 0 2>/dev/null
/build/scripts/dtc/fdtoverlay -i "$OUT/gts28ltexx-base.dtb" -o "$OUT/gts28ltexx-arm64.dtb" "$OUT/bootargs.dtbo"
/build/scripts/dtc/fdtoverlay -i "$OUT/gts28ltexx-base.dtb" -o /tmp/roundtrip.dtb "$OUT/bootargs.dtbo" && rm /tmp/roundtrip.dtb
echo ">>> what the overlay changed"
/build/scripts/dtc/dtc -I dtb -O dts "$OUT/gts28ltexx-arm64.dtb" 2>/dev/null > "$OUT/arm64.dts"
grep -n "bootargs\|psci\|enable-method\|linux,initrd" "$OUT/arm64.dts" | grep -v "^.*phandle" | head -n 6
python3 - "$OUT/arm64.dts" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
cur, found, clock_units = [], {}, []
for line in lines:
    s = line.strip()
    m = re.match(r"^([a-zA-Z0-9_+,.@-]+)\s*\{$", s)
    if m:
        cur.append(m.group(1))
    elif s == "};":
        if cur:
            cur.pop()
    elif s.startswith("compatible") and "samsung,exynos5433-cmu-" in s:
        clock_units.append("/" + "/".join(cur))
    elif s.startswith(("power-domains", "status")):
        found.setdefault("/" + "/".join(cur), []).append(s)
def off(path):
    notes = found.get(path, [])
    return "power-domains" not in " ".join(notes) or any(note.startswith('status = "disabled"') for note in notes)
missing = 0
for path in clock_units:
    if not off(path):
        print("UNWANTED: a clock unit in a power domain is still enabled:", path)
        missing = 1
for path in ("/soc@0/pinctrl@114b0000",):
    if not off(path):
        print("UNWANTED: the AUD pin controller is still enabled:", path)
        missing = 1
in_domain = [p for p in clock_units if "power-domains" in " ".join(found.get(p, []))]
print(f"clock units in the tree: {len(clock_units)}; in a power domain: {len(in_domain)}"
      + (", all disabled" if not missing else ", NOT all disabled"))
sys.exit(missing)
PY
cd "$OUT" && ls -la Image init gts28ltexx-base.dtb gts28ltexx-arm64.dtb && sha256sum Image gts28ltexx-base.dtb gts28ltexx-arm64.dtb init
echo ">>> header of the Image"
od -A x -t x4 -N 64 Image
echo ">>> done"
