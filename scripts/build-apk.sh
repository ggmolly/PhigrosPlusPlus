#!/usr/bin/env bash
# usage: build-apk.sh <folder with base.apk and split_*.apk>, writes the signed apks of Phigros++ to out/, installed
# as $PACKAGE next to the game (make runs this)
set -euo pipefail
SRC=$(realpath "${1:?usage: build-apk.sh <apk folder>}")
MOD=$(dirname "$(dirname "$(realpath "$0")")")
OUT=$MOD/out
KEY=$MOD/keystore.jks
LIB=lib/arm64-v8a

[ -f "$MOD/build/libphigrospp.so" ] || { echo "build/libphigrospp.so is missing, run make" >&2; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT"

unzip -q -o -j "$SRC/split_config.arm64_v8a.apk" "$LIB/libmain.so" -d "$MOD/build"
python3 -I "$MOD/scripts/patch_libmain.py" "$MOD/build/libmain.so" "$MOD/build/libmain.patched.so" >/dev/null

for apk in "$SRC"/*.apk; do
  name=$(basename "$apk")
  libs=()
  [ "$name" != split_config.arm64_v8a.apk ] ||
    libs=("$LIB/libmain.so=$MOD/build/libmain.patched.so" "$LIB/libphigrospp.so=$MOD/build/libphigrospp.so")
  python3 -I "$MOD/scripts/patch_apk.py" "$apk" "$OUT/$name" "${PACKAGE:?}" "${libs[@]}"
done

[ -f "$KEY" ] || keytool -genkeypair -keystore "$KEY" -alias mod -keyalg RSA -keysize 2048 -validity 36500 \
  -storepass phigrosmod -keypass phigrosmod -dname CN=phigros-mod >/dev/null 2>&1
for apk in "$OUT"/*.apk; do
  apksigner sign --v1-signing-enabled false --ks "$KEY" --ks-pass pass:phigrosmod --ks-key-alias mod "$apk"
done
# the splits don't name their min sdk, android 7 is the first to read v2 signatures
apksigner verify --min-sdk-version 24 "$OUT/split_config.arm64_v8a.apk"
rm -f "$OUT"/*.idsig
echo "built: $OUT"
