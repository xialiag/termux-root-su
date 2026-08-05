#!/bin/bash
# build.sh — compile binaries and package Magisk module zip
# Usage: ./build.sh [VERSION]
#   e.g. ./build.sh v2.2

set -euo pipefail

VERSION="${1:-v2.2}"
MODULE_NAME="termux-root-su"
OUTDIR="build"
ZIPFILE="${MODULE_NAME}-${VERSION}.zip"

# --- Detect cross compiler ---
if command -v aarch64-linux-gnu-gcc &>/dev/null; then
    CC=aarch64-linux-gnu-gcc
    STRIP=aarch64-linux-gnu-strip
else
    CC=gcc
    STRIP=strip
fi

echo "== Building ${MODULE_NAME} ${VERSION} =="
echo "   CC=${CC}"

mkdir -p "${OUTDIR}"

# --- Compile ---
for src in magisk-proxy su-relay test-proxy-client; do
    echo "   Compiling ${src}..."
    ${CC} -O2 -Wall -Wextra -static -o "${OUTDIR}/${src}" "src/${src}.c"
done

# --- Strip ---
for bin in magisk-proxy su-relay test-proxy-client; do
    ${STRIP} "${OUTDIR}/${bin}" 2>/dev/null || true
done

echo "   Binaries:"
ls -la "${OUTDIR}/"

# --- Package zip ---
echo "== Packaging ${ZIPFILE} =="
TMPDIR=$(mktemp -d)
mkdir -p "${TMPDIR}/META-INF/com/google/android"

# Module files
cp module.prop "${TMPDIR}/"
cp service.sh "${TMPDIR}/"
cp boot-completed.sh "${TMPDIR}/"
cp META-INF/com/google/android/update-binary "${TMPDIR}/META-INF/com/google/android/"

# Binaries
cp "${OUTDIR}/magisk-proxy" "${TMPDIR}/"
cp "${OUTDIR}/su-relay" "${TMPDIR}/"

# Create zip
(cd "${TMPDIR}" && zip -r9 "${OLDPWD}/${ZIPFILE}" .)
rm -rf "${TMPDIR}"

echo "   Output: ${ZIPFILE}"
ls -la "${ZIPFILE}"
echo "== Done =="
