#!/usr/bin/env bash
# usage: push.sh [--core | --reset], copies mods/ and examples/ (and with --core the core lua) to the device, where they
# override the bundle's. --reset removes them and any downloaded bundle, so the device runs the built-in one
set -euo pipefail
MOD=$(dirname "$(dirname "$(realpath "$0")")")
ROOT=/sdcard/Android/data/${PACKAGE:?}/files/phigros++

case ${1:-} in
  --reset) adb shell "rm -rf $ROOT/core/* $ROOT/bundle $ROOT/skipped $ROOT/mods/*" ;;
  --core) adb push -q "$MOD"/phigrospp/lua/*.lua "$ROOT/core/" ;;
  *)
    adb shell "rm -rf $ROOT/mods/*" && adb push -q "$MOD/mods/." "$ROOT/mods/"
    [ ! -d "$MOD/examples" ] || adb push -q "$MOD/examples/." "$ROOT/mods/"
    ;;
esac
# adb makes what it pushes the shell's, folders the app can't open
adb shell "find $ROOT/mods $ROOT/core -mindepth 1 -user shell -exec chmod a+rwX {} +"
