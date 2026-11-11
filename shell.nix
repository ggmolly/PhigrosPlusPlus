# everything the Makefile and scripts/ call, loaded by direnv (.envrc)
let
  # pinned, so everyone builds the same apks from the same sources
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/13e53762c5afaf384d4614e94527a9ccfafe41d0.tar.gz";
    sha256 = "sha256-pgG/CO+txdf2sA2z6DsM+2G3F9ajfIp/3BMC4wfKMDY=";
  };
  pkgs = import nixpkgs { config = { allowUnfree = true; android_sdk.accept_license = true; }; };
  ndk = (pkgs.androidenv.composeAndroidPackages { includeNDK = true; }).ndk-bundle;
in
pkgs.mkShell {
  packages = with pkgs; [
    # before android-tools, whose own python would come first
    (python3.withPackages (p: [ p.lief p.pillow ]))
    android-tools # adb
    aapt # aapt2, reads the game's version
    apksigner
    apksigcopier # make verify
    jdk # keytool, makes keystore.jks
    cmake
    ninja
    nodejs
    zip
    unzip
    lua54Packages.luacheck
  ];
  ANDROID_NDK = "${ndk}/libexec/android-sdk/ndk-bundle";
}
