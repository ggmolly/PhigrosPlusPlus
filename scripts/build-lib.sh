#!/usr/bin/env bash
# usage: build-lib.sh <apk folder>, builds build/libphigrospp.so (lua, the il2cpp bridge, dobby and the bundle) for the
# game in that folder with the android ndk of shell.nix (make runs this)
set -euo pipefail
APKS=$(realpath "${1:?usage: build-lib.sh <apk folder>}")
MOD=$(dirname "$(dirname "$(realpath "$0")")")
SRC=$MOD/phigrospp
LUA=$MOD/vendor/lua-5.4.7/src
DOBBY=$MOD/vendor/dobby # github.com/jmpews/Dobby at b0176de574, later commits don't build
NACL=$MOD/vendor/tweetnacl # tweetnacl.cr.yp.to 20140427
OUT=$MOD/build
mkdir -p "$OUT"

NDK=${ANDROID_NDK:?run it in the nix shell of shell.nix}
CC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang

if [ ! -f "$OUT/dobby/libdobby.a" ]; then
  cmake -S "$DOBBY" -B "$OUT/dobby" -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release -DDOBBY_DEBUG=OFF -DPlugin.SymbolResolver=OFF >/dev/null
  cmake --build "$OUT/dobby" --target dobby_static >/dev/null
fi

# downloaded bundles only run on the game they list, so the one this library ships with must be listed
GAME=$(aapt2 dump badging "$APKS/base.apk" | sed -n "s/^package:.* versionName='\([^']*\)'.*/\1/p")
grep -qx "$GAME" "$SRC/GAMES" || { echo "add the game version $GAME to phigrospp/GAMES" >&2; exit 1; }

"$MOD/scripts/bundle.sh"
node -e '
  const fs = require("fs");
  const [bundle, key] = process.argv.slice(1);
  const bytes = (data) => [...data].join(",");
  process.stdout.write(`static const char builtin[] = {${bytes(fs.readFileSync(bundle))},0};\n`);
  process.stdout.write(`static const unsigned char release_key[] = {${bytes(Buffer.from(fs.readFileSync(key, "ascii").trim(), "hex"))}};\n`);
' "$OUT/phigrospp.bundle" "$SRC/release.pub" > "$OUT/bundle.h"

sources=()
for file in "$LUA"/*.c; do
  case $(basename "$file") in lua.c | luac.c) ;; *) sources+=("$file") ;; esac
done

"$CC" -shared -fPIC -O2 -std=gnu11 -fvisibility=hidden -Wall -Wno-unused-function \
  -DTHUNKS=1024 -DLUA_USE_POSIX -DLUA_USE_DLOPEN -DNATIVE="$(cat "$SRC/NATIVE")" -DGAME="\"$GAME\"" \
  -I"$LUA" -I"$DOBBY/include" -I"$NACL" -I"$OUT" \
  "${sources[@]}" "$SRC/phigrospp.c" "$SRC/sync.c" "$SRC/bundle.c" "$SRC/thunks.S" "$OUT/dobby/libdobby.a" \
  -o "$OUT/libphigrospp.so" -l:libc++_static.a -l:libc++abi.a -llog -ldl -lm \
  -Wl,--gc-sections -Wl,--exclude-libs,ALL -Wl,-z,max-page-size=16384 -Wl,--build-id=none -s
echo "built: $OUT/libphigrospp.so ($(stat -c %s "$OUT/libphigrospp.so") bytes)"
