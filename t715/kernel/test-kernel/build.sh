#!/bin/bash
# Builds the arm64 test kernel in the project's build container; nothing in the user's trees is written.
# The two files under overlay/ (patches/0001: the Exynos MCT keeps time without the ARM counter)
# are mounted over the release tree's own, read-only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="${T715_KERNEL_DIR:?set T715_KERNEL_DIR to the kernel source tree}"
VOLUME="${KBUILD_ARM64_VOLUME:-t715-kbuild-arm64-loader}"
docker volume create "$VOLUME" >/dev/null
MOUNTS=()
while IFS= read -r f; do
    [ -f "$SRC/$f" ] || { echo "overlay/$f has no counterpart in the release tree"; exit 1; }
    MOUNTS+=(-v "$HERE/overlay/$f:/src/$f:ro")
done < <(cd "$HERE/overlay" && find . -type f ! -name '.DS_Store' | sed 's|^./||' | sort)
[ "${#MOUNTS[@]}" -gt 0 ] || { echo "overlay/ is empty"; exit 1; }
docker run --rm --platform linux/arm64 \
    -v "$SRC:/src:ro" "${MOUNTS[@]}" -v "$VOLUME:/build" -v "$HERE:/work" -w /src \
    t715-kbuild bash /work/build-inner.sh
