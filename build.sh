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
# Clean stale artifacts so leftovers from older builds never get packaged
rm -f "${OUTDIR}/magisk-proxy" "${OUTDIR}/su-relay" "${OUTDIR}/su"

if [ "$BUILD_FROM_SRC" = "1" ]; then
    # --- 从源码编译 ---
    # musl 优先: 静态 glibc 的 rseq 调用在部分 Android seccomp 策略下触发
    # SIGSYS (Bad system call), musl 静态二进制无此问题。
    if command -v musl-gcc &>/dev/null; then
        CC=musl-gcc
        STRIP=strip
    elif command -v aarch64-linux-gnu-gcc &>/dev/null; then
        CC=aarch64-linux-gnu-gcc
        STRIP=aarch64-linux-gnu-strip
    else
        CC=gcc
        STRIP=strip
    fi

    echo "== Compiling ${MODULE_NAME} ${VERSION} from source =="
    echo "   CC=${CC}"

    for src in magisk-proxy su; do
        echo "   Compiling ${src}..."
        ${CC} -O2 -Wall -Wextra -static -o "${OUTDIR}/${src}" "src/${src}.c"
        ${STRIP} "${OUTDIR}/${src}" 2>/dev/null || true
    done
else
    # --- 使用 prebuilt 二进制（与线上运行版本一致）---
    echo "== Packaging ${MODULE_NAME} ${VERSION} (prebuilt) =="
    for bin in magisk-proxy su; do
        if [ ! -f "prebuilt/${bin}" ]; then
            echo "ERROR: prebuilt/ 目录缺少 ${bin}"
            echo "  请先运行 './build.sh ${VERSION} --build' 从源码编译"
            exit 1
        fi
        cp "prebuilt/${bin}" "${OUTDIR}/${bin}"
    done
fi

echo "   Binaries:"
ls -la "${OUTDIR}/magisk-proxy" "${OUTDIR}/su"

# --- Package zip ---
echo "== Packaging ${ZIPFILE} =="
rm -f "${ZIPFILE}"
TMPDIR=$(mktemp -d)
mkdir -p "${TMPDIR}/META-INF/com/google/android"

cp module.prop "${TMPDIR}/"
cp service.sh "${TMPDIR}/"
cp boot-completed.sh "${TMPDIR}/"
cp DEBUG_NOTES.md "${TMPDIR}/"
cp META-INF/com/google/android/update-binary "${TMPDIR}/META-INF/com/google/android/"
cp "${OUTDIR}/magisk-proxy" "${TMPDIR}/"
cp "${OUTDIR}/su" "${TMPDIR}/"

(cd "${TMPDIR}" && zip -r9 "${OLDPWD}/${ZIPFILE}" .)
rm -rf "${TMPDIR}"

echo "   Output: ${ZIPFILE}"
ls -la "${ZIPFILE}"
echo "== Done =="
