# everything the Makefile and scripts/ call, loaded by direnv (.envrc)
let
  # pinned, so everyone builds the same apks from the same sources
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/13e53762c5afaf384d4614e94527a9ccfafe41d0.tar.gz";
    sha256 = "sha256-pgG/CO+txdf2sA2z6DsM+2G3F9ajfIp/3BMC4wfKMDY=";
  };
  pkgs = import nixpkgs { config = { allowUnfree = true; android_sdk.accept_license = true; }; };
  ndk = (pkgs.androidenv.composeAndroidPackages { includeNDK = true; }).ndk-bundle;
  # apple's headers and library stubs, which clang and lld build the ios library against
  iosSdk = pkgs.fetchzip {
    url = "https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS16.5.sdk.tar.xz";
    stripRoot = false; # cmake wants a path with /iPhoneOS in it
    hash = "sha256-g7WXMcwMeJMzRZPm3QVL5iIRPQjJEv8mT1/laFPqk8Y=";
  };
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
    llvmPackages.clang-unwrapped # clang for ios, the ndk has its own
    llvmPackages.lld
    llvmPackages.llvm # llvm-install-name-tool for cmake, llvm-strip and llvm-otool
    libimobiledevice # idevicesyslog, make ios-logs
  ];
  ANDROID_NDK = "${ndk}/libexec/android-sdk/ndk-bundle";
  IOS_SDK = "${iosSdk}/iPhoneOS16.5.sdk";
}
