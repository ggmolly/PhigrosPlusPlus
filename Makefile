# phigros++ development against the device plugged in over adb, see the wiki's Development page

APKS ?= ../apks/Phigros-4.0.1.2
# Phigros++ installs as its own app, next to the game
export PACKAGE := sh.molly.phigrosplusplus
LIB := build/libphigrospp.so
SPLIT := out/split_config.arm64_v8a.apk

# every target talks to the same device or files, one at a time
.NOTPARALLEL:

.PHONY: all lib apk verify install install-full push push-core reset start stop restart logs dev release publish clean

all: apk

lib: $(LIB)
$(LIB): $(wildcard phigrospp/* phigrospp/lua/* mods/* mods/*/* vendor/lua-5.4.7/src/* vendor/tweetnacl/*) \
		scripts/build-lib.sh scripts/bundle.sh $(APKS)/base.apk
	scripts/build-lib.sh $(APKS)

apk: $(SPLIT)
$(SPLIT): $(LIB) scripts/build-apk.sh scripts/patch_libmain.py scripts/patch_apk.py $(wildcard $(APKS)/*.apk)
	scripts/build-apk.sh $(APKS)

# checks that the apks of a release (RELEASE=<folder>) are these, signature aside
verify: $(SPLIT)
	set -e; for apk in $(RELEASE)/*.apk; do apksigcopier compare --min-sdk-version 24 $$apk out/$${apk##*/}; echo "same: $${apk##*/}"; done

# only the native split, the game data and the other splits stay
install: $(SPLIT)
	adb install-multiple -p $(PACKAGE) $(SPLIT)

install-full: $(SPLIT)
	adb install-multiple -r out/*.apk

push:
	scripts/push.sh

push-core:
	scripts/push.sh --core

reset:
	scripts/push.sh --reset

start:
	adb shell monkey -p $(PACKAGE) -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

stop:
	adb shell am force-stop $(PACKAGE)

restart: stop start

logs:
	adb logcat -s 'phigros++' DEBUG

# the signed bundle, its version line, the lib and the installer's manifest in out/ (needs the release key, see
# scripts/release.sh)
release: $(LIB)
	scripts/release.sh

# a github release of phigrospp/VERSION with what release made. the installer has its own releases
# (github.com/ggmolly/PhigrosPlusPlus-Installer) and patches the game with this one
publish: release
	gh release create v$$(cat phigrospp/VERSION) out/phigrospp.bundle out/phigrospp.version out/phigrospp.installer \
		out/libphigrospp.so --title "Phigros++ $$(cat phigrospp/VERSION)" --generate-notes --latest

dev: install push
	adb logcat -c
	$(MAKE) restart logs

clean:
	rm -rf build out
