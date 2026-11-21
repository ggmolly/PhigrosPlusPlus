# phigros++ development against the device plugged in over adb, see the wiki's Development page

APKS ?= ../apks/Phigros-4.1.0
# a folder holding the game's decrypted Phigros.ipa, for make ipa
IPA ?= ../apks/Phigros-ios-4.0.4
# Phigros++ installs as its own app, next to the game
export PACKAGE := sh.molly.phigrosplusplus
LIB := build/libphigrospp.so
DEX := build/picker.dex
SPLIT := out/split_config.arm64_v8a.apk
DYLIB := build/libphigrospp.dylib
SOURCES := $(wildcard phigrospp/* phigrospp/lua/* mods/* mods/*/* vendor/lua/* vendor/tweetnacl/* vendor/opus/*/*) \
	scripts/build-lib.sh scripts/bundle.sh

# every target talks to the same device or files, one at a time
.NOTPARALLEL:

.PHONY: all lib apk ipa ios-logs verify install install-full push push-core reset start stop restart logs profile dev release publish clean

all: apk

lib: $(LIB)
$(LIB): $(SOURCES) $(APKS)/base.apk $(DEX)
	scripts/build-lib.sh $(APKS)

# the Fragment phigrospp.pick opens android's file picker with, as a dex the bundle carries
$(DEX): phigrospp/Picker.java
	rm -rf build/picker
	javac -Xlint:-options -cp $(ANDROID_PLATFORMS)/*/android.jar -d build/picker $<
	$(ANDROID_BUILD_TOOLS)/*/d8 --release --min-api 26 --lib $(ANDROID_PLATFORMS)/*/android.jar --output build/picker \
		build/picker/phigrospp/*.class
	mv build/picker/classes.dex $@

apk: $(SPLIT)
$(SPLIT): $(LIB) scripts/build-apk.sh scripts/patch_libmain.py scripts/patch_apk.py $(wildcard $(APKS)/*.apk)
	scripts/build-apk.sh $(APKS)

# the game's ipa with phigros++ in it, for AltStore or SideStore to sign and install (see the wiki's Development page)
ipa: build/Phigros++.ipa
HOOKED := $(wildcard phigrospp/*.c phigrospp/lua/*.lua mods/*.lua mods/*/*.lua)
build/Phigros++.ipa: $(DYLIB) scripts/patch_ipa.py scripts/patch_apk.py $(IPA)/Phigros.ipa $(IPA)/dump/script.json $(HOOKED)
	python3 -I scripts/patch_ipa.py $(IPA)/Phigros.ipa $@ $(DYLIB) $(IPA)/dump/script.json $(HOOKED)
$(DYLIB): $(SOURCES) $(IPA)/Phigros.ipa $(DEX)
	scripts/build-lib.sh $(IPA)

ios-logs:
	idevicesyslog -m libphigrospp

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

# where the game's main thread spends SECONDS of play, by C# method, and a flame graph of every thread
profile:
	python3 scripts/profile.py $(APKS)/dump/script.json $(or $(SECONDS),10)

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
