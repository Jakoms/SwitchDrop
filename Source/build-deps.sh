#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
PREFIX="$ROOT/.build/deps-$TARGET"
SRC="$ROOT/.build/src-$TARGET"
STAMP="$(shasum -a 256 Source/libmtp-dbi-extension.inc Source/build-deps.sh ThirdParty/SHA256SUMS | shasum -a 256 | cut -d ' ' -f 1)"
if [ -f "$PREFIX/.source-stamp" ] && [ -f "$PREFIX/lib/libmtp.9.dylib" ] && [ -f "$PREFIX/lib/libusb-1.0.0.dylib" ] && [ "$(cat "$PREFIX/.source-stamp")" = "$STAMP" ]; then exit 0; fi
command -v pkg-config >/dev/null || { echo 'Install pkg-config: brew install pkgconf' >&2; exit 1; }
mkdir -p "$PREFIX" "$SRC"
(cd ThirdParty && shasum -a 256 -c SHA256SUMS)
tar -xzf ThirdParty/libmtp-1.1.23.tar.gz -C "$SRC"
tar -xjf ThirdParty/libusb-1.0.30.tar.bz2 -C "$SRC"
cat Source/libmtp-dbi-extension.inc >> "$SRC/libmtp-1.1.23/src/libmtp.c"
printf "LIBMTP_SwitchDrop_List\n" >> "$SRC/libmtp-1.1.23/src/libmtp.sym"
export MACOSX_DEPLOYMENT_TARGET="$TARGET"
export CFLAGS="-O2 -mmacosx-version-min=$TARGET"
export LDFLAGS="-mmacosx-version-min=$TARGET"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
JOBS="$(sysctl -n hw.ncpu)"
(cd "$SRC/libusb-1.0.30" && ac_cv_func_pipe2=no ./configure --prefix="$PREFIX" --disable-static --enable-shared && make -j"$JOBS" && make install)
(cd "$SRC/libmtp-1.1.23" && ./configure --prefix="$PREFIX" --disable-static --enable-shared --disable-doxygen --disable-mtpz && make -j"$JOBS" && make install)

printf "%s\n" "$STAMP" > "$PREFIX/.source-stamp"
