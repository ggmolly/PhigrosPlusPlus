#!/usr/bin/env bash
# usage: build-lib.sh <game folder>, builds the library (lua, the il2cpp bridge, dobby and the bundle) for the game in
# that folder with the tools of shell.nix (make runs this): build/libphigrospp.so with the android ndk for a folder of
# apks, build/libphigrospp.dylib with clang and the ios sdk for one holding Phigros.ipa
set -euo pipefail
GAMEDIR=$(realpath "${1:?usage: build-lib.sh <game folder>}")
MOD=$(dirname "$(dirname "$(realpath "$0")")")
SRC=$MOD/phigrospp
LUA=$MOD/vendor/lua # github.com/lua/lua at v5.4.7
DOBBY=$MOD/vendor/dobby # github.com/jmpews/Dobby at b0176de574, later commits don't build
NACL=$MOD/vendor/tweetnacl # tweetnacl.cr.yp.to 20140427
OPUS=$MOD/vendor/opus # github.com/xiph/opus at v1.6.1, the linker drops all but the decoder
TINF=$MOD/vendor/tinf # github.com/jibsen/tinf at v1.2.1, inflates the block areas of .phc charts
OUT=$MOD/build
mkdir -p "$OUT"

if [ -f "$GAMEDIR/Phigros.ipa" ]; then
  SDK=${IOS_SDK:?run it in the nix shell of shell.nix}
  TARGET=arm64-apple-ios15.0
  PLATFORM=ios LIB=libphigrospp.dylib
  # ios has no system(), so lua's os.execute says no shell (lua's own option, the vendored code stays as it is)
  CC=(clang -target "$TARGET" -isysroot "$SDK" '-Dl_system(cmd)=((cmd) == NULL ? 0 : -1)')
  DOBBY_FLAGS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT="$SDK"
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_C_COMPILER=clang
    -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_C_COMPILER_TARGET="$TARGET" -DCMAKE_CXX_COMPILER_TARGET="$TARGET"
    -DCMAKE_ASM_COMPILER_TARGET="$TARGET" -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DPlugin.SymbolResolver=ON) # its code patcher looks up a function of the system with it
  # nothing is exported: dyld runs the constructor, the rest is found through it
  LINK=(-fuse-ld=lld -install_name @executable_path/Frameworks/$LIB -framework AudioToolbox -framework CoreFoundation
    -lobjc -lc++ -Wl,-dead_strip -Wl,-exported_symbols_list,/dev/null)
  GAME=$(unzip -p "$GAMEDIR/Phigros.ipa" 'Payload/*.app/Info.plist' |
    python3 -I -c 'import plistlib, sys; print(plistlib.loads(sys.stdin.buffer.read())["CFBundleShortVersionString"])')
else
  NDK=${ANDROID_NDK:?run it in the nix shell of shell.nix}
  PLATFORM=android LIB=libphigrospp.so
  CC=("$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang")
  DOBBY_FLAGS=(-DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a
    -DANDROID_PLATFORM=android-24 -DPlugin.SymbolResolver=OFF)
  LINK=(-l:libc++_static.a -l:libc++abi.a -llog -lmediandk -ldl -Wl,--gc-sections -Wl,--exclude-libs,ALL
    -Wl,-z,max-page-size=16384 -Wl,--build-id=none)
  GAME=$(aapt2 dump badging "$GAMEDIR/base.apk" | sed -n "s/^package:.* versionName='\([^']*\)'.*/\1/p")
fi

if [ ! -f "$OUT/dobby-$PLATFORM/libdobby.a" ]; then
  cmake -S "$DOBBY" -B "$OUT/dobby-$PLATFORM" -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "${DOBBY_FLAGS[@]}" \
    -DCMAKE_BUILD_TYPE=Release -DDOBBY_DEBUG=OFF >/dev/null
  cmake --build "$OUT/dobby-$PLATFORM" --target dobby_static >/dev/null
fi

# downloaded bundles only run on the game they list, so the one this library ships with must be listed
grep -qx "$PLATFORM:$GAME" "$SRC/GAMES" || { echo "add $PLATFORM:$GAME to phigrospp/GAMES" >&2; exit 1; }

"$MOD/scripts/bundle.sh"
node -e '
  const fs = require("fs");
  const [bundle, key] = process.argv.slice(1);
  const bytes = (data) => [...data].join(",");
  process.stdout.write(`static const char builtin[] = {${bytes(fs.readFileSync(bundle))},0};\n`);
  process.stdout.write(`static const unsigned char release_key[] = {${bytes(Buffer.from(fs.readFileSync(key, "ascii").trim(), "hex"))}};\n`);
' "$OUT/phigrospp.bundle" "$SRC/release.pub" > "$OUT/bundle.h"

sources=()
for file in "$LUA"/*.c "$OPUS"/src/*.c "$OPUS"/celt/*.c "$OPUS"/silk/*.c; do
  case $(basename "$file") in lua.c | ltests.c | onelua.c | *_demo.c | *_compare.c) ;; *) sources+=("$file") ;; esac
done

"${CC[@]}" -shared -fPIC -O2 -std=gnu11 -fvisibility=hidden -Wall -Wno-unused-function \
  -DTHUNKS=1024 -DLUA_USE_POSIX -DOPUS_BUILD -DOPUS_EXPORT= -DUSE_ALLOCA -DHAVE_LRINTF -DHAVE_LRINT -DLUA_USE_DLOPEN -DNATIVE="$(cat "$SRC/NATIVE")" -DGAME="\"$GAME\"" \
  -I"$LUA" -I"$DOBBY/include" -I"$NACL" -I"$TINF/src" -I"$OPUS/include" -I"$OPUS/celt" -I"$OPUS/silk" -I"$OPUS/silk/float" -I"$OUT" \
  "${sources[@]}" "$TINF/src/tinflate.c" "$SRC/phigrospp.c" "$SRC/$PLATFORM.c" "$SRC/sync.c" "$SRC/bundle.c" "$SRC/phc.c" "$SRC/media.c" \
  "$SRC/thunks.S" "$OUT/dobby-$PLATFORM/libdobby.a" -o "$OUT/${LIB/./.sym.}" -lm "${LINK[@]}"
# the symbols stay in build/libphigrospp.sym.*, for make profile to name its functions
llvm-strip --strip-all -o "$OUT/$LIB" "$OUT/${LIB/./.sym.}"
echo "built: $OUT/$LIB ($(stat -c %s "$OUT/$LIB") bytes)"
