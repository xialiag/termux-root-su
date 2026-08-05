#!/bin/bash
# build.sh — package Magisk module zip
# Usage:
#   ./build.sh [VERSION]           # 使用 prebuilt 二进制（默认，和线上一致）
#   ./build.sh [VERSION] --build   # 从源码编译

set -euo pipefail

VERSION="${1:-v2.2}"
MODULE_NAME="termux-root-su"
OUTDIR="build"
ZIPFILE="${MODULE_NAME}-${VERSION}.zip"
BUILD_FROM_SRC=0

for arg in "$@"; do
    [ "$arg" = "--build" ] && BUILD_FROM_SRC=1
done

mkdir -p "${OUTDIR}"

if [ "$BUILD_FROM_SRC" = "1" ]; then
    # --- 从源码编译 ---
    if command -v aarch64-linux-gnu-gcc &>/dev/null; then
        CC=aarch64-linux-gnu-gcc
        STRIP=aarch64-linux-gnu-strip
    else
        CC=gcc
        STRIP=strip
    fi

    echo "== Compiling ${MODULE_NAME} ${VERSION} from source =="
    echo "   CC=${CC}"

    for src in magisk-proxy su-relay; do
        echo "   Compiling ${src}..."
        ${CC} -O2 -Wall -Wextra -static -o "${OUTDIR}/${src}" "src/${src}.c"
        ${STRIP} "${OUTDIR}/${src}" 2>/dev/null || true
    done
else
    # --- 使用 prebuilt 二进制（与线上运行版本一致）---
    echo "== Packaging ${MODULE_NAME} ${VERSION} (prebuilt) =="
    if [ ! -f prebuilt/magisk-proxy ] || [ ! -f prebuilt/su-relay ]; then
        echo "ERROR: prebuilt/ 目录缺少二进制文件"
        echo "  请先运行 './build.sh ${VERSION} --build' 从源码编译"
        exit 1
    fi
    cp prebuilt/magisk-proxy "${OUTDIR}/magisk-proxy"
    cp prebuilt/su-relay "${OUTDIR}/su-relay"
fi

echo "   Binaries:"
ls -la "${OUTDIR}/magisk-proxy" "${OUTDIR}/su-relay"

# --- Package zip ---
echo "== Packaging ${ZIPFILE} =="
TMPDIR=$(mktemp -d)
mkdir -p "${TMPDIR}/META-INF/com/google/android"

cp module.prop "${TMPDIR}/"
cp service.sh "${TMPDIR}/"
cp boot-completed.sh "${TMPDIR}/"
cp META-INF/com/google/android/update-binary "${TMPDIR}/META-INF/com/google/android/"
cp "${OUTDIR}/magisk-proxy" "${TMPDIR}/"
cp "${OUTDIR}/su-relay" "${TMPDIR}/"

(cd "${TMPDIR}" && zip -r9 "${OLDPWD}/${ZIPFILE}" .)
rm -rf "${TMPDIR}"

echo "   Output: ${ZIPFILE}"
ls -la "${ZIPFILE}"
echo "== Done =="
