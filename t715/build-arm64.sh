#!/bin/bash
# build-arm64.sh: the SM-T715 (Galaxy Tab S2 8.0 LTE, Exynos 5433) release kernel configuration
# built for arm64, in the project's build container.  Nothing in the owner's trees is written.
#
# Usage:
#   build-arm64.sh                 configuration, Image, modules, device trees, results
#   build-arm64.sh --config-only   stop after the configuration (kernel-out/.config, the report)
#   build-arm64.sh --clean         empty the build volume first: a full rebuild
#   build-arm64.sh -j N            parallel jobs (default 8; or JOBS=N in the environment)
#
# What it does, every time:
#   1. configuration: the release configuration (kernel-out/config-release-arm32) with the lines
#      of kernel-out/config-arm64.changes, then those of kernel-out/config-arm64.local if that
#      file exists, then `make olddefconfig`.  The result is checked symbol by symbol against
#      the release and against config-arm64.gone and config-arm64.new, and config-report.md is
#      written from them.  An unexplained difference stops the script.
#   2. kernel: make Image modules (no debug information: DEBUG_INFO_NONE, as in the release).
#   3. modules: modules_install, packed as modules.tar.xz.
#   4. device tree: gts28ltexx-base.dtb (the board dts as the release builds it),
#      gts28ltexx-bootargs.dtb (the same with bootargs-overlay.dts applied, which sets
#      /chosen/bootargs and nothing else; the script fails on any other difference).
#   5. results in kernel-out/: Image, Image.sha256, SHA256SUMS, .config, config-report.md,
#      modules.tar.xz, the two DTBs, System.map, kernel.release, build.log, build-summary.txt.
#
# Sources: the clone in linux/ (branch t715-arm64), mounted read-only at /src.  Output: the
# Docker volume t715-kbuild-arm64-port, mounted at /build.  The build is incremental: run the
# script again after a change; --clean for a rebuild from scratch.
#
# The clone sits on a case-insensitive volume, where 13 paths of the Linux tree (xt_HL.c and
# xt_hl.c, ...) cannot all exist: the working tree holds one file of each pair, under the name
# that survived.  The commit is intact, so the script takes each missing file from the commit
# (kernel-out/casefix/, rebuilt here every time) and builds through a VIEW of the clone made in
# the container: every entry of the clone by a symbolic link, except the directories that hold a
# missing path, which become real directories of links with the missing names added.  A file
# mounted over a missing name would not do: the compiler finds headers by path, but make decides
# whether a source exists from the directory listing, and a mount is never listed.
#
# Environment (all optional):
#   JOBS=N                    parallel jobs
#   RELEASE_CONFIG=path       where to copy the release configuration from when
#                             kernel-out/config-release-arm32 does not exist yet
#   KBUILD_BUILD_TIMESTAMP, KBUILD_BUILD_VERSION, KBUILD_BUILD_USER, KBUILD_BUILD_HOST
#                             the identity the kernel shows in `uname -a`.  A fixed date (the
#                             release's practice): two builds of one commit and one configuration
#                             give the same Image.  Raise KBUILD_BUILD_VERSION to tell builds apart.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
CLONE="${T715_ARM64_CLONE:-$HERE/linux}"
OUT="${T715_ARM64_OUT:-$HERE/kernel-out}"
IMAGE="${T715_KBUILD_IMAGE:-t715-kbuild}"
VOLUME="${T715_ARM64_VOLUME:-t715-kbuild-arm64-port}"
BRANCH=t715-arm64
BOARD_DTS="${T715_BOARD_DTS:-arch/arm64/boot/dts/exynos/exynos5433-gts28ltexx.dts}"   # the arm64 board (smp/ patch 0003): the 32-bit board plus the eight-core method and stage 1
RELEASE_CONFIG_DEFAULT="${T715_RELEASE_CONFIG:-}"
[ -n "$RELEASE_CONFIG_DEFAULT" ] || RELEASE_CONFIG_DEFAULT="$(cd "$(dirname "$0")/"../.. && pwd)/omarchy-tab-s2/out/mainline-v105/.config" || true
JOBS="${JOBS:-8}"
SLOT_BYTES=$((64 * 1024 * 1024))
SLOT_HEADER_BYTES=4096
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Sat Nov 21 12:00:00 UTC 2026}"
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-1}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-t715-arm64}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-port}"
CLEAN=0
CONFIG_ONLY=0

# ===================================================================================== inside the container
inner() {
    local config_only=0 clean=0 jobs=8
    while [ $# -gt 0 ]; do
        case "$1" in
            --config-only) config_only=1 ;;
            --clean) clean=1 ;;
            -j) shift; jobs="$1" ;;
            *) echo "build-arm64.sh: unknown option for the container: $1" >&2; exit 2 ;;
        esac
        shift
    done
    cd /src
    # git must accept the repository whoever owns it on the host.  And it must not re-read the
    # 80 000 files of the tree: the index was written on the host, where inode numbers and
    # change times differ, so here only the modification time and the size of a file are
    # compared (3 minutes became 6 seconds; the answer is the same as on the host).
    export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/src \
           GIT_CONFIG_KEY_1=core.checkStat GIT_CONFIG_VALUE_1=minimal \
           GIT_CONFIG_KEY_2=core.trustctime GIT_CONFIG_VALUE_2=false
    local tree_state branch_name commit
    if [ -z "$(git --no-optional-locks status --porcelain --untracked-files=no)" ]; then tree_state=clean; else tree_state=MODIFIED; fi
    branch_name=$(git rev-parse --abbrev-ref HEAD)
    commit=$(git rev-parse HEAD)

    # The kernel's release string (the name of the modules directory too) is what the kernel's
    # own scripts/setlocalversion makes of the real clone.  It is passed to the build in
    # LOCALVERSION because the view holds no repository (through a tree of links git would see
    # every file as modified) and would give no string at all.
    local kv suffix
    kv="$(sed -n -e 's/^VERSION = //p' -e 's/^PATCHLEVEL = //p' -e 's/^SUBLEVEL = //p' -e 's/^EXTRAVERSION = //p' /src/Makefile | tr '\n' '.' | sed -E 's/\.+$//; s/^([0-9]+)\.([0-9]+)\.([0-9]+)$/\1.\2.\3/')"
    suffix="$(KERNELVERSION="$kv" bash /src/scripts/setlocalversion --no-local /src)"
    case "$suffix" in
        "$kv"-g[0-9a-f]*|"$kv"-[0-9][0-9][0-9][0-9][0-9]-g[0-9a-f]*) ;;
        *) echo "build-arm64.sh: cannot form the kernel release string from $kv (got '$suffix')" >&2; exit 1 ;;
    esac
    LOCALVERSION="${suffix#"$kv"}"
    [ "$tree_state" = clean ] || LOCALVERSION="${LOCALVERSION}-dirty"
    export LOCALVERSION
    echo ">>> [arm64] source: $commit on $branch_name; tree: $tree_state; kernel release ${kv}${LOCALVERSION}"
    if [ "$clean" = 1 ]; then
        echo ">>> [arm64] --clean: emptying the build volume"
        find /build -mindepth 1 -delete
    fi

    # ---------------------------------------------------------------- the view of the clone
    # Every entry of the clone by a link, dot files excepted (no repository: see above).  Each
    # directory that holds a path the host cannot keep becomes a real directory of links, with
    # the missing names added, pointing at the committed content.
    local VIEW=/view
    rm -rf "$VIEW"
    mkdir -p "$VIEW"
    local e
    for e in /src/*; do
        ln -s "$e" "$VIEW/$(basename "$e")"
    done
    link_all() {     # $1: a directory of the clone; $2: the new directory of links
        local x
        for x in "$1"/* "$1"/.[!.]* "$1"/..?*; do
            [ -e "$x" ] || [ -L "$x" ] || continue
            ln -s "$x" "$2/$(basename "$x")"
        done
    }
    view_add() {     # $1: a path the host cannot keep; $2: the file with its committed content
        local path="$1" target="$2" parts k p="" real
        IFS='/' read -r -a parts <<< "$path"
        for ((k = 0; k < ${#parts[@]} - 1; k++)); do
            p="${p:+$p/}${parts[k]}"
            if [ -L "$VIEW/$p" ]; then          # still a link to the clone's directory: open it
                real=$(readlink "$VIEW/$p")
                rm "$VIEW/$p"
                mkdir "$VIEW/$p"
                link_all "$real" "$VIEW/$p"
            fi
        done
        ln -s "$target" "$VIEW/$path"
    }
    local n=0 p
    while IFS= read -r p; do
        n=$((n + 1))
        view_add "$p" "/work/casefix/$n/file"
    done < /work/casefix/.paths
    if ! (cd "$VIEW" && sha256sum --quiet -c /work/casefix/.sha256); then
        echo "build-arm64.sh: a path taken from the commit does not hold what the commit holds" >&2
        exit 1
    fi
    echo ">>> [arm64] view of the clone at $VIEW: $n paths taken from the commit"
    cd "$VIEW"

    # ---------------------------------------------------------------- configuration
    echo ">>> [arm64] configuration"
    # The two configurations are written beside /build/.config, which is replaced only when its
    # content changes: an unchanged one keeps the build system from recomputing everything that
    # depends on it (the release string included).
    # 1. what arm64 alone makes of the release configuration (the reference of the report)
    cp /work/config-release-arm32 /build/.config.plain
    make -s ARCH=arm64 O=/build KCONFIG_CONFIG=/build/.config.plain olddefconfig > /work/config.log 2>&1
    # 2. the same with our lines
    cp /work/config-release-arm32 /build/.config.final
    apply_changes() {
        local f="$1" tmp line
        [ -f "$f" ] || return 0
        tmp=$(mktemp)
        grep -vE '^[[:space:]]*(#|$)' "$f" > "$tmp" || true
        local -a syms=()
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            local sym
            sym=$(printf '%s\n' "$line" | sed -nE 's/^(# )?CONFIG_([A-Za-z0-9_]+)(=| is not set$).*/\2/p')
            [ -n "$sym" ] || { echo "build-arm64.sh: not a configuration line in $f: $line" >&2; rm -f "$tmp"; exit 2; }
            syms+=("$sym")
        done < "$tmp"
        if [ ${#syms[@]} -gt 0 ]; then
            local alt
            alt=$(IFS='|'; echo "${syms[*]}")
            grep -vE "^(# )?CONFIG_(${alt})(=| is not set\$)" /build/.config.final > /build/.config.tmp || true
            mv /build/.config.tmp /build/.config.final
            cat "$tmp" >> /build/.config.final
        fi
        rm -f "$tmp"
    }
    apply_changes /work/config-arm64.changes
    apply_changes /work/config-arm64.local
    make -s ARCH=arm64 O=/build KCONFIG_CONFIG=/build/.config.final olddefconfig >> /work/config.log 2>&1
    python3 - /build/.config.final /build/.config.plain /work <<'PY'
import re, sys

FINAL, PLAIN, WORK = sys.argv[1], sys.argv[2], sys.argv[3]
LINE = re.compile(r"^(?:# )?CONFIG_([A-Za-z0-9_]+)(?:=(.*)| is not set)$")

def load(path):
    on, val = {}, {}
    for line in open(path, encoding="utf-8", errors="replace"):
        m = LINE.match(line.rstrip("\n"))
        if not m:
            continue
        s, v = m.group(1), m.group(2)
        if v is None:            # "# CONFIG_X is not set"
            continue
        val[s] = v
        if v in ("y", "m"):
            on[s] = v
    return on, val

def rows(path):
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("#") or not line.strip():
            continue
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3:
            out.append(p[:3])
    return out

def changes(path):
    out = []
    try:
        f = open(path, encoding="utf-8")
    except OSError:
        return out
    for line in f:
        m = LINE.match(line.rstrip("\n"))
        if m and not line.startswith("# CONFIG_"):
            out.append((m.group(1), m.group(2)))
    return out

rel, relval = load(WORK + "/config-release-arm32")
fin, finval = load(FINAL)
plain, plainval = load(PLAIN)
gone, new = rows(WORK + "/config-arm64.gone"), rows(WORK + "/config-arm64.new")
GONE = {r[0]: r[2] for r in gone}
NEW = {r[0]: (r[1], r[2]) for r in new}
ours = changes(WORK + "/config-arm64.changes")
ours += changes(WORK + "/config-arm64.local")
OURS = {s: v for s, v in ours}
errors, warnings = [], []

# every symbol built by the release keeps its value, unless it is listed as gone
for s in sorted(rel):
    if s in GONE:
        if s in plain:
            errors.append("%s is listed as gone but is built (final %s, plain %s)" % (s, fin.get(s), plain.get(s)))
        elif s in fin:
            # gone from the plain translation, brought back by our own lines (COMPAT since 2.1.0)
            print("%s: gone from the plain translation, built again by our lines (%s)" % (s, fin[s]))
    elif s in OURS and plain.get(s) == rel[s] and (fin.get(s) or "n") == OURS[s]:
        # set by our own lines, "CONFIG_X=n" included (a choice: USB_DWC3_DUAL_ROLE ends USB_DWC3_GADGET)
        print("%s: the release builds it %s, our lines make it %s" % (s, rel[s], OURS[s]))
    elif fin.get(s) != rel[s] or plain.get(s) != rel[s]:
        errors.append("%s: the release builds it %s, arm64 gives %s (plain %s) and it is in neither list" % (s, rel[s], fin.get(s, "n"), plain.get(s, "n")))
# every symbol arm64 adds is listed
for s in sorted(plain):
    if s not in rel and s not in NEW:
        errors.append("%s: arm64 builds it %s, the release does not, and it is not in config-arm64.new" % (s, plain[s]))
# a symbol the final configuration builds and neither the release nor the plain translation does
# is a consequence of our lines (the final configuration is the plain one plus those lines)
consequences = sorted(s for s in fin if s not in rel and s not in plain and s not in OURS)
if consequences:
    print("our lines also turn on, through Kconfig: " + " ".join(consequences))
# the lists are exact
for s in GONE:
    if s not in rel:
        errors.append("%s is in config-arm64.gone but the release does not build it" % s)
for s, (value, _) in NEW.items():
    if s in rel:
        errors.append("%s is in config-arm64.new but the release already builds it %s" % (s, rel[s]))
    if value == "-":
        if s in fin:
            errors.append("%s should be removed again by our lines and is built %s" % (s, fin[s]))
    elif s not in plain:
        errors.append("%s is in config-arm64.new but the plain translation does not build it" % s)

# what must hold for this port
MUST_Y = ["ARM64", "ARM64_4K_PAGES", "ARM64_VA_BITS_39", "ARM64_PA_BITS_48", "MODULES", "DEBUG_INFO_NONE", "ARCH_EXYNOS",
          "LOCALVERSION_AUTO", "S3C2410_WATCHDOG", "SAMSUNG_SEC_LOG_CONSOLE", "PSTORE_RAM", "EXYNOS_PM_DOMAINS"]
# COMPAT left the list in 2.1.0: Waydroid's arm64 image runs 32-bit services and apps.
MUST_N = ["COMPILE_TEST", "ARM64_VA_BITS_52", "ARM64_PA_BITS_52", "ARM64_LPA2", "DEBUG_INFO_BTF", "KASAN",
          "RANDOMIZE_BASE", "KEXEC", "MODULE_SIG", "EXYNOS_IOMMU", "ARM64_16K_PAGES", "ARM64_64K_PAGES"]
MUST_VAL = {"ARM64_VA_BITS": "39", "ARM64_PA_BITS": "48", "PGTABLE_LEVELS": "3", "NR_CPUS": "8", "HZ": "250",
            "PANIC_TIMEOUT": "5"}
for s in MUST_Y:
    if fin.get(s) != "y":
        errors.append("%s must be y and is %s" % (s, fin.get(s, "n")))
for s in MUST_N:
    if s in fin:
        errors.append("%s must not be built and is %s" % (s, fin[s]))
for s, v in MUST_VAL.items():
    if finval.get(s) != v:
        errors.append("%s must be %s and is %s" % (s, v, finval.get(s)))
for s, v in OURS.items():
    if s in MUST_N and fin.get(s):
        warnings.append("%s is built (%s): it is on the list of what this port keeps off" % (s, fin[s]))
if finval.get("INITRAMFS_SOURCE", '""').strip('"') != "":
    warnings.append("INITRAMFS_SOURCE is set: the Image carries a built-in initramfs")
for s in ("CMDLINE_FORCE",):
    if s in fin:
        warnings.append("%s is set: the device tree's bootargs are ignored" % s)

print("release: %d built in, %d modules; plain arm64: %d built in, %d modules; final: %d built in, %d modules" % (
    sum(1 for v in rel.values() if v == "y"), sum(1 for v in rel.values() if v == "m"),
    sum(1 for v in plain.values() if v == "y"), sum(1 for v in plain.values() if v == "m"),
    sum(1 for v in fin.values() if v == "y"), sum(1 for v in fin.values() if v == "m")))
for w in warnings:
    print("WARNING: " + w)
if errors:
    for e in errors:
        print("ERROR: " + e)
    sys.exit(1)
print("configuration checked: %d symbols unchanged, %d gone, %d new, %d set by our lines, no unexplained difference" % (
    sum(1 for s in rel if s not in GONE), len(GONE), len(NEW), len(OURS)))
PY
    # the build's configuration is replaced only when its content changed (see above)
    if ! cmp -s /build/.config.final /build/.config; then
        cp /build/.config.final /build/.config
        echo ">>> [arm64] the configuration changed: /build/.config replaced"
    else
        echo ">>> [arm64] the configuration is the one already in the build volume"
    fi
    cp /build/.config /work/.config

    # ---------------------------------------------------------------- report
    echo ">>> [arm64] report"
    python3 - /build/.config.final /build/.config.plain /work "$VIEW" <<'PY'
import os, re, sys

FINAL, PLAIN, WORK, SRC = sys.argv[1:5]
LINE = re.compile(r"^(?:# )?CONFIG_([A-Za-z0-9_]+)(?:=(.*)| is not set)$")
PROMPT = re.compile(r'^\s*(?:bool|boolean|tristate|string|int|hex|prompt)\s+"(.*)"')

def load(path):
    on, val = {}, {}
    for line in open(path, encoding="utf-8", errors="replace"):
        m = LINE.match(line.rstrip("\n"))
        if not m or m.group(2) is None:
            continue
        val[m.group(1)] = m.group(2)
        if m.group(2) in ("y", "m"):
            on[m.group(1)] = m.group(2)
    return on, val

def rows(path):
    return [l.rstrip("\n").split("\t")[:3] for l in open(path, encoding="utf-8", errors="replace")
            if l.strip() and not l.startswith("#")]

def changes(path):
    out = []
    if os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            m = LINE.match(line.rstrip("\n"))
            if m and not line.startswith("# CONFIG_"):
                out.append((m.group(1), m.group(2)))
    return out

def prompts(names):
    """The prompt of each symbol, from the Kconfig files of the arm64 configuration."""
    want, found, files, seen, order = set(names), {}, [], set(), []
    def visit(path):
        if path in seen:
            return
        seen.add(path)
        order.append(path)
        for line in open(path, encoding="utf-8", errors="replace"):
            m = re.match(r'^\s*(?:rsource|orsource|source)\s+"([^"]*)"', line)
            if not m:
                continue
            spec = m.group(1).replace("$(SRCARCH)", "arm64").replace("$(ARCH)", "arm64")
            import glob
            base = os.path.dirname(path) if m.group(0).strip().startswith(("rsource", "orsource")) else SRC
            for p in sorted(glob.glob(os.path.join(base, spec))):
                visit(p)
    visit(os.path.join(SRC, "Kconfig"))
    current = None
    for kc in order:
        for line in open(kc, encoding="utf-8", errors="replace"):
            s = line.strip()
            d = re.match(r"^(?:menuconfig|config)\s+([A-Za-z0-9_]+)\b", s)
            if d:
                current = d.group(1)
                continue
            if current in want and current not in found:
                p = PROMPT.match(line)
                if p:
                    found[current] = p.group(1)
    return found

def cell(text):
    return str(text).replace("|", "\\|")

rel, relval = load(WORK + "/config-release-arm32")
fin, finval = load(FINAL)
plain, plainval = load(PLAIN)
gone = rows(WORK + "/config-arm64.gone")
new = rows(WORK + "/config-arm64.new")
ours = changes(WORK + "/config-arm64.changes") + changes(WORK + "/config-arm64.local")
GONE = {r[0]: r for r in gone}
NEW = {r[0]: r for r in new}
OURS = dict(ours)

# changed by us: everything that differs between what arm64 alone makes of the release
# configuration and the final configuration
direct, follow = [], []
for s in sorted(set(plainval) | set(finval)):
    a, b = plainval.get(s, "n"), finval.get(s, "n")
    if a == b:
        continue
    (direct if s in OURS else follow).append((s, a, b))
for s, v in ours:
    if plainval.get(s, "n") == finval.get(s, "n"):
        direct.append((s, plainval.get(s, "n"), finval.get(s, "n") + " (same as the arm64 default)"))

pr = prompts([s for s in rel if s not in GONE] + [r[0] for r in gone] + [r[0] for r in new])
out = []
w = out.append
w("# The release configuration translated to arm64: symbol by symbol")
w("")
w("Generated by `build-arm64.sh` from `config-release-arm32`, `config-arm64.changes`,")
w("`config-arm64.gone` and `config-arm64.new`.  Reference: the release configuration of the 32-bit")
w("kernel (%d built in, %d modules).  Result: %d built in, %d modules." % (
    sum(1 for v in rel.values() if v == "y"), sum(1 for v in rel.values() if v == "m"),
    sum(1 for v in fin.values() if v == "y"), sum(1 for v in fin.values() if v == "m")))
w("")
w("How to read it.  `make olddefconfig` on the release file under `ARCH=arm64` keeps every symbol")
w("it can and drops the rest (the \"plain\" column).  Our own lines are then applied.  A symbol is")
w("\"unchanged\" when the release builds it and the final configuration builds it the same way.")
w("")
w("## 1. Changed by us")
w("")
w("Everything that differs between what arm64 alone makes of the release configuration and the")
w("final configuration.  Only one line is written by hand (`config-arm64.changes`); the rest follows")
w("from it through Kconfig.")
w("")
w("| Symbol | Release | arm64 alone | Final | Why |")
w("|---|---|---|---|---|")
for s, a, b in direct:
    why = "the only line of config-arm64.changes: 39 bits of virtual address are enough for this SoC (the owner's decision); the arm64 default is 52"
    w("| `%s` | %s | %s | %s | %s |" % (s, relval.get(s, "n"), a, b, why))
for s, a, b in follow:
    w("| `%s` | %s | %s | %s | follows from the line above: %s |" % (
        s, relval.get(s, "n"), a, b, {
            "ARM64_VA_BITS_52": "the virtual address space choice",
            "ARM64_PA_BITS_52": "with 4 KiB pages, 52-bit addresses exist only with a 52-bit virtual space; 48 bits stay",
            "ARM64_PA_BITS_48": "the physical address space choice: 48 bits, the only one left with a 39-bit virtual space",
            "ARM64_LPA2": "no 52-bit physical addresses, so no large physical address extension",
            "ARM64_VA_BITS": "the size of the virtual address space",
            "ARM64_PA_BITS": "the size of the physical address space",
            "PGTABLE_LEVELS": "39 bits need 3 levels of translation tables, 52 need 5",
            "ARCH_MMAP_RND_BITS_MAX": "the largest mmap randomisation follows the virtual address size (its bits minus 15); the 18 bits kept (the arm64 default; the release had 8) still fit",
        }.get(s, "a Kconfig consequence")))
w("")
w("## 2. Gone, with the reason")
w("")
w("Symbols the release builds and the arm64 kernel does not.  `%d` of them.  Nothing in this table is" % len(gone))
w("built by the tablet's arm64 kernel: each line says why it cannot be, or why it is not needed.")
w("Two of them remove a function of the tablet (the LTE modem, suspend to RAM); the secondary cores")
w("are another workstream's.")
w("")
w("| Symbol | Release | Reason |")
w("|---|---|---|")
for r in sorted(gone):
    w("| `%s` | %s | %s |" % (r[0], r[1], cell(r[2])))
w("")
w("## 3. Unchanged")
w("")
w("Symbols the release builds, built the same way for arm64 (`%d`: %d built in, %d modules).  The" % (
    sum(1 for s in rel if s not in GONE), sum(1 for s in rel if s not in GONE and rel[s] == "y"),
    sum(1 for s in rel if s not in GONE and rel[s] == "m")))
w("third column is the option's own text in Kconfig.")
w("")
w("| Symbol | Value | Option |")
w("|---|---|---|")
for s in sorted(k for k in rel if k not in GONE):
    w("| `%s` | %s | %s |" % (s, rel[s], cell(pr.get(s) or "(no prompt: selected by another option)")))
w("")
w("## 4. New: what arm64 adds")
w("")
w("Symbols arm64 builds and the release does not (`%d`).  None is a decision of ours: they are the" % len(new))
w("architecture's own options, taken at their default.  A value of `-` marks one that our line")
w("removes again (table 1).")
w("")
w("| Symbol | Value | Reason |")
w("|---|---|---|")
for r in sorted(new):
    w("| `%s` | %s | %s |" % (r[0], r[1], cell(r[2])))
w("")
w("## 5. Values that are not y or m")
w("")
w("| Symbol | Release | Final |")
w("|---|---|---|")
for s in sorted(set(relval) | set(finval)):
    if s in rel or s in fin:
        continue
    a, b = relval.get(s, "-"), finval.get(s, "-")
    if a != b:
        w("| `%s` | %s | %s |" % (s, cell(a), cell(b)))
w("")
open(WORK + "/config-report.md", "w").write("\n".join(out) + "\n")
print("config-report.md: %d changed by us, %d gone, %d unchanged, %d new, %d lines" % (
    len(direct) + len(follow), len(gone), sum(1 for s in rel if s not in GONE), len(new), len(out)))
PY

    if [ "$config_only" = 1 ]; then
        echo ">>> [arm64] --config-only: the configuration is in kernel-out/.config, the report in kernel-out/config-report.md"
        return 0
    fi

    # ---------------------------------------------------------------- kernel
    echo ">>> [arm64] Image and modules (-j$jobs); the log is build.log"
    if ! make -j"$jobs" ARCH=arm64 O=/build Image modules > /work/build.log 2>&1; then
        echo ">>> [arm64] FAILED: the errors, from build.log:" >&2
        grep -n -B3 -A4 -E 'error:|fatal error|undefined reference|No rule to make target|Stop\.|Error [0-9]|Killed|Permission denied|Read-only file system' /work/build.log | head -n 120 >&2 || true
        exit 1
    fi
    tail -n 4 /work/build.log

    echo ">>> [arm64] modules"
    rm -rf /build/modroot
    make -s ARCH=arm64 O=/build INSTALL_MOD_PATH=/build/modroot modules_install > /work/modules-install.log 2>&1
    # sorted, owned by root, dated of the build identity: two builds give the same archive
    rm -f /build/modules.tar.xz
    tar -C /build/modroot --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime="@$(date -u -d "$KBUILD_BUILD_TIMESTAMP" +%s)" -cJf /build/modules.tar.xz .

    echo ">>> [arm64] device tree"
    make -s -j"$jobs" ARCH=arm64 O=/build scripts/dtc/ >> /work/config.log 2>&1
    DTC=/build/scripts/dtc/dtc
    FDTOVERLAY=/build/scripts/dtc/fdtoverlay
    cpp -nostdinc -I"$VIEW/scripts/dtc/include-prefixes" -undef -D__DTS__ -x assembler-with-cpp \
        "$VIEW/$BOARD_DTS" | "$DTC" -O dtb -o /work/gts28ltexx-base.dtb -b 0 2> /work/dtc-warnings.txt
    cpp -nostdinc -I"$VIEW/scripts/dtc/include-prefixes" -undef -D__DTS__ -x assembler-with-cpp \
        /work/bootargs-overlay.dts | "$DTC" -O dtb -o /build/bootargs.dtbo -b 0 2>> /work/dtc-warnings.txt
    "$FDTOVERLAY" -i /work/gts28ltexx-base.dtb -o /work/gts28ltexx-bootargs.dtb /build/bootargs.dtbo
    python3 - "$DTC" /work <<'PY'
import difflib, re, subprocess, sys

DTC, WORK = sys.argv[1], sys.argv[2]
def dts(path):
    r = subprocess.run([DTC, "-I", "dtb", "-O", "dts", path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("dtc cannot read " + path + ": " + r.stderr)
    return r.stdout.splitlines()

base, final = dts(WORK + "/gts28ltexx-base.dtb"), dts(WORK + "/gts28ltexx-bootargs.dtb")
changed = [l for l in difflib.unified_diff(base, final, lineterm="", n=0) if l[:1] in "+-" and l[:3] not in ("+++", "---")]
removed = [l[1:].strip() for l in changed if l[0] == "-"]
added = [l[1:].strip() for l in changed if l[0] == "+"]
want = re.search(r'bootargs\s*=\s*"([^"]*)"', open(WORK + "/bootargs-overlay.dts").read()).group(1)
ok = len(removed) == 1 and len(added) == 1 and removed[0].startswith("bootargs = ") and added[0] == 'bootargs = "%s";' % want
if not ok:
    sys.exit("the overlay changed more than /chosen/bootargs:\n  removed: %s\n  added: %s" % (removed, added))
print("overlay: %d -> %d characters of bootargs, the only difference between the two device trees" % (
    len(removed[0]) - len('bootargs = "";'), len(want)))
PY

    # ---------------------------------------------------------------- results
    echo ">>> [arm64] results"
    local release
    release=$(cat /build/include/config/kernel.release)
    if [ "$release" != "$kv$LOCALVERSION" ]; then
        echo "build-arm64.sh: the kernel release is '$release', not '${kv}${LOCALVERSION}' as formed from the clone" >&2
        exit 1
    fi
    printf '%s\n' "$release" > /work/kernel.release
    cp /build/arch/arm64/boot/Image /build/System.map /build/modules.tar.xz /build/.config /work/
    rm -f /work/SHA256SUMS /work/Image.sha256
    (cd /work && sha256sum Image gts28ltexx-base.dtb gts28ltexx-bootargs.dtb modules.tar.xz System.map .config \
        bootargs-overlay.dts config-release-arm32 config-arm64.changes config-arm64.gone config-arm64.new > SHA256SUMS.new \
        && mv SHA256SUMS.new SHA256SUMS && sha256sum Image > Image.sha256)
    local image_bytes image_footprint dtb_bytes room
    image_bytes=$(stat -c %s /work/Image)
    image_footprint=$(od -A n -t u4 -j 16 -N 4 /work/Image | tr -d ' ')
    dtb_bytes=$(( $(stat -c %s /work/gts28ltexx-base.dtb) + $(stat -c %s /work/gts28ltexx-bootargs.dtb) ))
    room=$((SLOT_BYTES - SLOT_HEADER_BYTES - image_bytes - dtb_bytes))
    {
        echo "commit:          $commit on $branch_name, tree $tree_state; built through a view of the clone ($n paths from the commit)"
        echo "kernel release:  $release"
        echo "configuration:   $(sha256sum /work/.config | cut -d' ' -f1)  .config ($(grep -c '=y$' /work/.config) built in, $(grep -c '=m$' /work/.config) modules)"
        echo "Image:           $image_bytes bytes ($((image_bytes / 1024 / 1024)) MiB $((image_bytes / 1024 % 1024)) KiB), sha256 $(cut -d' ' -f1 /work/Image.sha256)"
        echo "                 footprint in memory (image_size, .bss included): $image_footprint bytes; magic at 0x38: $(dd if=/work/Image bs=1 skip=56 count=4 2>/dev/null) (ARM\\x64 expected); first instruction: $(od -A n -t x4 -N 4 /work/Image | tr -d ' ')"
        echo "device trees:    gts28ltexx-base.dtb $(stat -c %s /work/gts28ltexx-base.dtb) bytes, gts28ltexx-bootargs.dtb $(stat -c %s /work/gts28ltexx-bootargs.dtb) bytes"
        echo "modules:         $(find /build/modroot -name '*.ko' | wc -l) modules in lib/modules/$release/, modules.tar.xz $(stat -c %s /work/modules.tar.xz) bytes"
        echo "build:           $(grep -c 'warning:' /work/build.log || true) warning lines, $(grep -c -E 'error:|Error [0-9]' /work/build.log || true) error lines in build.log"
        echo "dtc:             $(grep -c 'Warning' /work/dtc-warnings.txt || true) warnings for the board dts and the overlay"
        echo "slot:            $((SLOT_BYTES / 1048576)) MiB = $SLOT_HEADER_BYTES bytes of header + Image + one device tree: $([ "$room" -ge 0 ] && echo "fits, $((room / 1024)) KiB left" || echo "DOES NOT FIT, $(((-room) / 1024)) KiB too much")"
        echo "identity:        #${KBUILD_BUILD_VERSION} ${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST}, ${KBUILD_BUILD_TIMESTAMP}"
    } > /work/build-summary.txt
    cat /work/build-summary.txt
}

# ========================================================================================= on the host
usage() {
    sed -n '2,/^set -euo pipefail/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1 ;;
        --config-only) CONFIG_ONLY=1 ;;
        -j) [ $# -ge 2 ] || usage 2; JOBS="$2"; shift ;;
        -j*) JOBS="${1#-j}" ;;
        -h|--help) usage 0 ;;
        inner) shift; inner "$@"; exit ;;
        *) echo "build-arm64.sh: unknown option: $1" >&2; usage 2 ;;
    esac
    shift
done

command -v docker >/dev/null || { echo "build-arm64.sh: docker is not installed" >&2; exit 1; }
command -v python3 >/dev/null || { echo "build-arm64.sh: python3 is needed on the host (for the case-fix list)" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "build-arm64.sh: Docker image $IMAGE not found" >&2; exit 1; }
mkdir -p "$OUT"
case "$VOLUME" in
    t715-kbuild-arm64-port) ;;
    *) echo "build-arm64.sh: refusing to use the volume $VOLUME: this workstream owns t715-kbuild-arm64-port only" >&2; exit 1 ;;
esac
case "$CLONE/" in
    "$HERE"/*) ;;
    *) echo "build-arm64.sh: $CLONE is outside $HERE" >&2; exit 1 ;;
esac
case "$OUT/" in
    "$HERE"/*) ;;
    *) echo "build-arm64.sh: $OUT is outside $HERE" >&2; exit 1 ;;
esac
git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 || { echo "build-arm64.sh: $CLONE is not a git repository" >&2; exit 1; }

branch=$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)
[ "$branch" = "$BRANCH" ] || echo "build-arm64.sh: WARNING: the clone is on branch $branch, not $BRANCH" >&2
head=$(git -C "$CLONE" rev-parse HEAD)
head12=${head:0:12}

# the release configuration is pinned once, then never read from the owner's tree again
if [ ! -f "$OUT/config-release-arm32" ]; then
    rc="${RELEASE_CONFIG:-$RELEASE_CONFIG_DEFAULT}"
    [ -f "$rc" ] || { echo "build-arm64.sh: $OUT/config-release-arm32 does not exist and the release configuration is not at $rc (RELEASE_CONFIG=path)" >&2; exit 1; }
    cp "$rc" "$OUT/config-release-arm32"
    echo ">>> release configuration pinned from $rc"
fi
for f in config-arm64.changes config-arm64.gone config-arm64.new bootargs-overlay.dts; do
    [ -f "$OUT/$f" ] || { echo "build-arm64.sh: $OUT/$f is missing" >&2; exit 1; }
done

# the paths the case-insensitive volume cannot keep: each taken from the commit, with the
# checksum the view must show for it
CASEFIX="$OUT/casefix"
mkdir -p "$CASEFIX"
: > "$CASEFIX/.paths.tmp"
: > "$CASEFIX/.sha256.tmp"
python3 -I - "$CLONE" > "$CASEFIX/.broken.tmp" <<'PY'
import os, subprocess, sys
os.chdir(sys.argv[1])
paths = [p.decode() for p in subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.split(b"\0") if p]
groups = {}
for p in paths:
    groups.setdefault(p.lower(), []).append(p)
listed = {}
for g in sorted(groups.values()):
    if len(g) > 1:
        for p in g:
            d, b = os.path.split(p)
            if d not in listed:
                try:
                    listed[d] = set(os.listdir(d))
                except OSError:
                    listed[d] = set()
            if b not in listed[d]:
                print(p)
PY
i=0
while IFS= read -r p; do
    i=$((i + 1))
    d="$CASEFIX/$i"
    mkdir -p "$d"
    # replaced only when its content changes, so that make sees no change in the others
    if ! git -C "$CLONE" show "HEAD:$p" | cmp -s - "$d/file"; then
        git -C "$CLONE" show "HEAD:$p" > "$d/file.tmp"
        mv -f "$d/file.tmp" "$d/file"
    fi
    git -C "$CLONE" show "HEAD:$p" | shasum -a 256 | sed "s|  -\$|  $p|" >> "$CASEFIX/.sha256.tmp"
    printf '%s\n' "$p" >> "$CASEFIX/.paths.tmp"
done < "$CASEFIX/.broken.tmp"
mv -f "$CASEFIX/.paths.tmp" "$CASEFIX/.paths"
mv -f "$CASEFIX/.sha256.tmp" "$CASEFIX/.sha256"
rm -f "$CASEFIX/.broken.tmp" "$CASEFIX/.mounts"
# a numbered directory above the current count is stale (the list shrank): removed
for d in "$CASEFIX"/*/; do
    n=$(basename "$d")
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$n" -gt "$i" ]; then
        rm -rf "$d"
    fi
done
echo ">>> source $head12 on $branch ($(git -C "$CLONE" status --porcelain | wc -l | tr -d ' ') uncommitted changes), $i paths taken from the commit, volume $VOLUME"

docker volume create "$VOLUME" >/dev/null
INNER_ARGS=(inner -j "$JOBS")
[ "$CLEAN" = 1 ] && INNER_ARGS+=(--clean)
[ "$CONFIG_ONLY" = 1 ] && INNER_ARGS+=(--config-only)
docker run --rm --platform linux/arm64 \
    -v "$CLONE:/src:ro" \
    -v "$VOLUME:/build" -v "$OUT:/work" \
    -v "$SELF:/build-inner.sh:ro" \
    -e KBUILD_BUILD_TIMESTAMP -e KBUILD_BUILD_VERSION -e KBUILD_BUILD_USER -e KBUILD_BUILD_HOST \
    "$IMAGE" bash /build-inner.sh "${INNER_ARGS[@]}"

# what only the host can tell: the volume's size, and that the kernel names the commit it was built from
if [ "$CONFIG_ONLY" = 0 ]; then
    release=$(cat "$OUT/kernel.release")
    case "$release" in
        *-g"$head12") ;;
        *) echo "build-arm64.sh: WARNING: the kernel release '$release' does not end in -g$head12: the kernel does not name its commit" >&2 ;;
    esac
    echo ">>> volume $VOLUME: $(docker run --rm --platform linux/arm64 -v "$VOLUME:/build" "$IMAGE" du -sh /build | cut -f1)"
fi
