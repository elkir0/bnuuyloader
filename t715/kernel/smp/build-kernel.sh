#!/bin/bash
# build-kernel.sh: compile test of the arm64 SMP patch for the SM-T715 (Exynos 5433), in the
# project's build container.  Nothing in the owner's trees is written, and nothing of the other
# work streams is.
#
# Usage:
#   smp/build-kernel.sh                 build from the clone linux-smp/ as it is on the disk
#   smp/build-kernel.sh --archive       build from what the branch HEAD commits (git archive into
#                                       the build volume: a case-correct tree, nothing uncommitted)
#   smp/build-kernel.sh --thermal       the boot configuration plus cpufreq-dt and CPU cooling (Image-thermal)
#   smp/build-kernel.sh --requested     instead of the configuration the owner's first test kernel
#                                       uses, the one asked for the compile test: the same with PM
#   JOBS=N                              parallel jobs (default 8)
#
# Two configurations, both allnoconfig plus a short list:
#   boot       the configuration of the owner's first arm64 test kernel (kernel/test-kernel/
#              build-inner.sh), plus HOTPLUG_CPU and ARM64_EXYNOS5433_SMP: the Image and the DTB
#              it gives can be booted.
#   requested  the same with PM (the owner's list for the compile test).  PM brings the Exynos
#              power domains in, which that small kernel must not probe: this one is for
#              compiling only.
#
# Sources: linux-smp/ (branch t715-arm64-smp), read-only at /src, with the two files of the
# owner's MCT patch (kernel/test-kernel/overlay/) mounted over the release tree's, as in the
# owner's build.sh: without them the kernel panics on this device (no architected timer).
# Output: the Docker volume t715-kbuild-arm64-port-smp at /build, and smp/build-kernel/ (Image,
# DTB, .config, logs, the stubs disassembled).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PORT="$(dirname "$HERE")"
CLONE="${T715_SMP_CLONE:-$PORT/linux-smp}"
TEST_KERNEL="${T715_TEST_KERNEL:-}"
[ -n "$TEST_KERNEL" ] || TEST_KERNEL="$(cd "$(dirname "$0")/".. && pwd)/test-kernel" || true
VOLUME="${KBUILD_ARM64_VOLUME:-t715-kbuild-arm64-port-smp}"
OUT="${T715_SMP_OUT:-$HERE/build-kernel}"
IMAGE="${T715_KBUILD_IMAGE:-t715-kbuild}"
JOBS="${JOBS:-8}"
FROM_ARCHIVE=0
CONFIGURATION=boot

while [ $# -gt 0 ]; do
    case "$1" in
        --archive) FROM_ARCHIVE=1 ;;
        --requested) CONFIGURATION=requested ;;
        --thermal) CONFIGURATION=thermal ;;
        -j) shift; JOBS="$1" ;;
        -j*) JOBS="${1#-j}" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
export SMP_JOBS="$JOBS" SMP_CONFIGURATION="$CONFIGURATION"

[ -d "$CLONE/.git" ] || { echo "no clone at $CLONE" >&2; exit 1; }
[ -d "$TEST_KERNEL/overlay" ] || { echo "the owner's overlay is not at $TEST_KERNEL" >&2; exit 1; }
mkdir -p "$OUT"
docker volume create "$VOLUME" >/dev/null

# The case-insensitive disk of the Mac cannot hold both of 14 pairs of files of the Linux tree
# that differ only by case (xt_DSCP.c and xt_dscp.c, ...).  Neither configuration builds any of
# them (netfilter, tools memory models), so they are left as they are; --archive is the build
# that does not depend on that.
MOUNTS=(-v "$VOLUME:/build" -v "$OUT:/work:rw" -v "$HERE:/smp:ro")
if [ "$FROM_ARCHIVE" = 1 ]; then
    COMMIT="$(git -C "$CLONE" rev-parse HEAD)"
    git -C "$CLONE" archive --format=tar "$COMMIT" | docker run --rm -i --platform linux/arm64 \
        -v "$VOLUME:/build" "$IMAGE" sh -c 'rm -rf /build/src && mkdir -p /build/src && tar -x -C /build/src'
    echo ">>> the tree of commit $COMMIT is in the volume (/build/src), built in /build/out-archive"
    SRC_IN_CONTAINER=/build/src
    export SMP_O=/build/out-archive
else
    MOUNTS+=(-v "$CLONE:/src:ro")
    SRC_IN_CONTAINER=/src
    export SMP_O=/build/out
fi
# the owner's two files of the MCT patch over the tree's own, read-only
while IFS= read -r f; do
    MOUNTS+=(-v "$TEST_KERNEL/overlay/$f:$SRC_IN_CONTAINER/$f:ro")
done < <(cd "$TEST_KERNEL/overlay" && find . -type f | sed 's|^./||' | sort)
# the owner's test init, read-only, for the Image that can be booted
[ -f "$TEST_KERNEL/init.c" ] && MOUNTS+=(-v "$TEST_KERNEL/init.c:/test-kernel/init.c:ro")

docker run --rm --platform linux/arm64 "${MOUNTS[@]}" -e SMP_JOBS -e SMP_CONFIGURATION -e SMP_O \
    -w "$SRC_IN_CONTAINER" "$IMAGE" bash /smp/build-kernel-inner.sh "$SRC_IN_CONTAINER"
