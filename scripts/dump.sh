#!/usr/bin/env bash
# usage: dump.sh <game folder>, writes <game folder>/dump/ (dump.cs, script.json, stringliteral.json, libil2cpp.so)
# from its apks or its decrypted Phigros.ipa, with the il2cppdumper of shell.nix (make ipa runs this)
set -euo pipefail
GAMEDIR=$(realpath "${1:?usage: dump.sh <game folder>}")
OUT=$GAMEDIR/dump
DUMPER=${IL2CPPDUMPER:?run it in the nix shell of shell.nix}
mkdir -p "$OUT"
if [ -f "$GAMEDIR/Phigros.ipa" ]; then # ios: the code is UnityFramework
  APP=Payload/Phigros.app
  unzip -p "$GAMEDIR/Phigros.ipa" $APP/Frameworks/UnityFramework.framework/UnityFramework > "$OUT/libil2cpp.so"
  unzip -p "$GAMEDIR/Phigros.ipa" $APP/Data/Managed/Metadata/global-metadata.dat > "$OUT/global-metadata.dat"
else
  unzip -p "$GAMEDIR/split_config.arm64_v8a.apk" lib/arm64-v8a/libil2cpp.so > "$OUT/libil2cpp.so"
  unzip -p "$GAMEDIR/base.apk" assets/bin/Data/Managed/Metadata/global-metadata.dat > "$OUT/global-metadata.dat"
fi
# the net7 build runs on the .net 8 runtime, the "may be protected" warning is harmless
DOTNET_ROLL_FORWARD=Major dotnet "$DUMPER" "$OUT/libil2cpp.so" "$OUT/global-metadata.dat" "$OUT" | tail -3
rm "$OUT/global-metadata.dat"
