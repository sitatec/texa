#!/usr/bin/env bash
#
# Build sherpa-onnx (submodule at ./sherpa-onnx) for Flutter, with
# onnxruntime STATICALLY linked into the sherpa-onnx library on every
# platform, and copy the artifacts into ./sherpa-onnx/flutter/.
#
# The result is self-contained: an app that depends on the Flutter
# plugins below installs and runs as-is -- there is NO separate
# libonnxruntime.so / libonnxruntime.dylib / onnxruntime.framework
# to add, embed, or ship alongside it.
#
#   target          build                                       artifact copied to
#   --------------- ------------------------------------------- ------------------------------------------------------------
#   ios             build-ios-shared-sherpa-with-               flutter/sherpa_onnx_ios/ios/sherpa_onnx_ios/
#                     static-onnxruntime.sh                       SherpaOnnxC.xcframework
#   macos           build-macos-shared-sherpa-with-             flutter/sherpa_onnx_macos/macos/sherpa_onnx_macos/
#                     static-onnxruntime.sh                       sherpa-onnx.xcframework
#                                                                   (macos-arm64_x86_64/libsherpa-onnx-c-api.dylib,
#                                                                    as expected by Package.swift + podspec)
#   android-arm64   build-android-arm64-v8a.sh flags, but       flutter/sherpa_onnx_android_arm64/android/src/main/
#                     BUILD_SHARED_LIBS=ON for sherpa-onnx      jniLibs/arm64-v8a/libsherpa-onnx-c-api.so
#                     itself and a static onnxruntime           (only this one .so; ditto for the combined
#                     (see build_android below)                  sherpa_onnx_android package)
#   android-armv7   same, armeabi-v7a                           flutter/sherpa_onnx_android_armeabi/android/src/main/
#                                                                   jniLibs/armeabi-v7a/libsherpa-onnx-c-api.so
#   web             build-wasm-simd-web.sh (onnxruntime is      flutter/sherpa_onnx_web/assets/
#                     always statically linked into WASM)         sherpa-onnx-wasm-web.{js,wasm} + sherpa-onnx-*.js
#
# Usage:
#   ./build-sherpa-onnx.sh [--skip-build] [--clean] [target ...]
#
#   target        all (default) | ios | macos | android | android-arm64 |
#                 android-armv7 | web
#   --skip-build  Skip building; only copy + verify artifacts that are
#                 already present in sherpa-onnx/build-*/.
#   --clean       Remove the selected targets' build directories in
#                 sherpa-onnx/ before building (forces a full rebuild).
#   -h, --help    Show this help.
#
# Environment (all optional):
#   ANDROID_NDK    Path to an Android NDK. If unset, the newest NDK under
#                  $ANDROID_HOME/ndk, $ANDROID_SDK_ROOT/ndk,
#                  ~/Library/Android/sdk/ndk or ~/Android/Sdk/ndk is used
#                  (the upstream Android scripts otherwise fall back to
#                  hard-coded paths on the upstream author's machine).
#   EMSCRIPTEN     Path to an Emscripten SDK (or have `emcc` on PATH, or
#                  an emsdk checkout at ~/emsdk). emsdk 4.0.23 is known
#                  to work upstream.
#   SHERPA_ONNX_ONNXRUNTIME_VERSION  onnxruntime version (default: the
#                  upstream default, currently 1.28.2).
#
# Notes:
#   - ios/macos can only be built on macOS with Xcode installed.
#   - Android is not built by literally running the upstream
#     build-android-*.sh scripts: with BUILD_SHARED_LIBS=ON they copy a
#     shared libonnxruntime.so next to libsherpa-onnx-c-api.so, and with
#     BUILD_SHARED_LIBS=OFF sherpa-onnx itself becomes a static .a that
#     Dart FFI cannot load. build_android() below therefore reuses the
#     upstream CMake invocation, but points SHERPA_ONNXRUNTIME_LIB_DIR /
#     SHERPA_ONNXRUNTIME_INCLUDE_DIR at the static onnxruntime package
#     (the same one the BUILD_SHARED_LIBS=OFF path downloads), so the
#     shared libsherpa-onnx-c-api.so absorbs onnxruntime statically.
#     The copy step also verifies (llvm-readelf, when available) that
#     the resulting .so does not depend on libonnxruntime.so, and the
#     iOS/macOS steps verify the same with otool.
#   - Trade-off: each artifact is larger (onnxruntime is baked in), and
#     if several plugins ever bundled their own copy, it would be
#     duplicated. That is the price of "just install and use".
#   - Built artifacts are git-ignored upstream (*.so, *.xcframework,
#     web assets); this script only populates your working tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHERPA_DIR="$SCRIPT_DIR/sherpa-onnx"
FLUTTER_DIR="$SHERPA_DIR/flutter"
ONNXRUNTIME_VERSION="${SHERPA_ONNX_ONNXRUNTIME_VERSION:-1.28.2}"

SKIP_BUILD=0
CLEAN=0
TARGETS=()

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  awk '/^set -euo pipefail/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --clean)      CLEAN=1 ;;
    all|ios|macos|android|android-arm64|android-armv7|web) TARGETS+=("$1") ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(all)

EXPANDED=()
for t in "${TARGETS[@]}"; do
  case "$t" in
    all)     EXPANDED+=(ios macos android-arm64 android-armv7 web) ;;
    android) EXPANDED+=(android-arm64 android-armv7) ;;
    *)       EXPANDED+=("$t") ;;
  esac
done
TARGETS=()
for t in "${EXPANDED[@]}"; do
  # shellcheck disable=SC2076
  [[ " ${TARGETS[*]:-} " =~ " $t " ]] || TARGETS+=("$t")
done

[ -d "$SHERPA_DIR" ]  || die "sherpa-onnx not found at $SHERPA_DIR (git submodule not initialised?)"
[ -d "$FLUTTER_DIR" ] || die "flutter plugins not found at $FLUTTER_DIR"
[ -f "$SHERPA_DIR/CMakeLists.txt" ] || die "$SHERPA_DIR does not look like a sherpa-onnx checkout"

want() {
  local t
  for t in "${TARGETS[@]}"; do [ "$t" = "$1" ] && return 0; done
  return 1
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required tool not found on PATH: $1"; }
require_file() { [ -e "$1" ] || die "expected build artifact not found: $1"; }

clean_dir() {
  if [ "$CLEAN" -eq 1 ] && [ -d "$SHERPA_DIR/$1" ]; then
    log "Removing $SHERPA_DIR/$1 (--clean)"
    rm -rf "$SHERPA_DIR/$1"
  fi
}

# Run an upstream build script (unless --skip-build) from $SHERPA_DIR.
run_build() {
  local script="$1"
  [ -f "$SHERPA_DIR/$script" ] || die "upstream build script not found: $SHERPA_DIR/$script"
  if [ "$SKIP_BUILD" -eq 1 ]; then
    log "Skipping build ($script) -- copying existing artifacts"
    return 0
  fi
  log "Building: ./$script  (in $SHERPA_DIR)"
  (cd "$SHERPA_DIR" && "./$script")
}

# Fail if a Mach-O binary dynamically depends on onnxruntime.
assert_no_onnxruntime_dep() {
  local bin="$1"
  command -v otool >/dev/null 2>&1 || return 0
  if otool -L "$bin" 2>/dev/null | grep -q "onnxruntime"; then
    otool -L "$bin" >&2
    die "$bin still dynamically depends on onnxruntime -- not self-contained"
  fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks (only for the selected targets / only when building)
# ---------------------------------------------------------------------------

if [ "$SKIP_BUILD" -eq 0 ]; then
  require_cmd cmake

  if want ios || want macos; then
    [ "$(uname -s)" = "Darwin" ] || die "ios/macos targets can only be built on macOS"
    require_cmd xcodebuild
    require_cmd wget   # upstream scripts download onnxruntime with wget
    require_cmd unzip
  fi

  if want android-arm64 || want android-armv7; then
    if [ -z "${ANDROID_NDK:-}" ] || [ ! -d "${ANDROID_NDK:-}" ]; then
      ANDROID_NDK=""
      for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
                 "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
        [ -n "$sdk" ] && [ -d "$sdk/ndk" ] || continue
        latest="$(find "$sdk/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
        [ -n "$latest" ] && ANDROID_NDK="$latest" && break
      done
    fi
    [ -n "${ANDROID_NDK:-}" ] && [ -f "$ANDROID_NDK/build/cmake/android.toolchain.cmake" ] \
      || die "no usable Android NDK found -- set ANDROID_NDK to an NDK installation"
    export ANDROID_NDK
    log "Using ANDROID_NDK=$ANDROID_NDK"
    require_cmd wget
    require_cmd unzip
    require_cmd make
  fi

  if want web; then
    if [ -z "${EMSCRIPTEN:-}" ] && ! command -v emcc >/dev/null 2>&1; then
      if [ -f "$HOME/Projects/emsdk/emsdk_env.sh" ]; then
        # shellcheck disable=SC1091
        . "$HOME/Projects/emsdk/emsdk_env.sh" >/dev/null
      fi
    fi
    command -v emcc >/dev/null 2>&1 || [ -n "${EMSCRIPTEN:-}" ] \
      || die "Emscripten not found -- install emsdk (4.0.23), source emsdk_env.sh, or set EMSCRIPTEN"
  fi
fi

# ---------------------------------------------------------------------------
# iOS (shared sherpa-onnx, static onnxruntime -> self-contained)
# ---------------------------------------------------------------------------
IOS_BUILD_DIR=build-ios-shared-sherpa-with-static-onnxruntime
if want ios; then
  clean_dir "$IOS_BUILD_DIR"
  run_build build-ios-shared-sherpa-with-static-onnxruntime.sh

  src="$SHERPA_DIR/$IOS_BUILD_DIR/SherpaOnnxC.xcframework"
  dst_dir="$FLUTTER_DIR/sherpa_onnx_ios/ios/sherpa_onnx_ios"
  dst="$dst_dir/SherpaOnnxC.xcframework"
  require_file "$src"
  log "Copying iOS xcframework -> ${dst#$SCRIPT_DIR/}"
  mkdir -p "$dst_dir"
  rm -rf "$dst"
  cp -a "$src" "$dst"
  require_file "$dst"
  found=0
  while IFS= read -r bin; do
    found=1
    assert_no_onnxruntime_dep "$bin"
  done < <(find "$dst" -name SherpaOnnxC -type f)
  [ "$found" -eq 1 ] || die "copied iOS xcframework contains no SherpaOnnxC binary: $dst"
fi

# ---------------------------------------------------------------------------
# macOS (shared sherpa-onnx, static onnxruntime -> self-contained)
# ---------------------------------------------------------------------------
MACOS_BUILD_DIR=build-macos-shared-sherpa-with-static-onnxruntime
if want macos; then
  clean_dir "$MACOS_BUILD_DIR"
  run_build build-macos-shared-sherpa-with-static-onnxruntime.sh

  src="$SHERPA_DIR/$MACOS_BUILD_DIR/sherpa-onnx.xcframework"
  dst_dir="$FLUTTER_DIR/sherpa_onnx_macos/macos/sherpa_onnx_macos"
  dst="$dst_dir/sherpa-onnx.xcframework"
  require_file "$src"
  log "Copying macOS xcframework -> ${dst#$SCRIPT_DIR/}"
  mkdir -p "$dst_dir"
  rm -rf "$dst"
  cp -a "$src" "$dst"
  require_file "$dst"
  found=0
  while IFS= read -r bin; do
    found=1
    assert_no_onnxruntime_dep "$bin"
  done < <(find "$dst" \( -name 'libsherpa-onnx-c-api.dylib' -o -name SherpaOnnxC \) -type f)
  [ "$found" -eq 1 ] || die "copied macOS xcframework contains no sherpa-onnx binary: $dst"
fi

# ---------------------------------------------------------------------------
# Android (shared sherpa-onnx, static onnxruntime -> single self-contained .so)
# ---------------------------------------------------------------------------

# build_android <abi> <static-ort-zip-name> <extra cmake args...>
# Mirrors upstream build-android-*.sh, except onnxruntime is the static
# package and sherpa-onnx stays shared (see header notes).
build_android() {
  local abi="$1" ort_pkg="$2"; shift 2
  local build_dir="$SHERPA_DIR/build-android-$abi-self-contained"
  if [ "$SKIP_BUILD" -eq 1 ]; then
    log "Skipping build (android $abi) -- copying existing artifacts"
    return 0
  fi
  [ "$CLEAN" -eq 1 ] && rm -rf "$build_dir"
  log "Building Android $abi (shared sherpa-onnx + static onnxruntime, in $build_dir)"
  (
    cd "$SHERPA_DIR"
    mkdir -p "$build_dir"
    cd "$build_dir"

    # Static onnxruntime for this ABI (same download the upstream
    # BUILD_SHARED_LIBS=OFF path uses).
    local ort_dir="$build_dir/onnxruntime-static"
    if [ ! -f "$ort_dir/lib/libonnxruntime.a" ]; then
      mkdir -p "$ort_dir"
      wget -c -q "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ONNXRUNTIME_VERSION}/${ort_pkg}-${ONNXRUNTIME_VERSION}.zip" \
        -O "$ort_dir/pkg.zip"
      unzip -q -o "$ort_dir/pkg.zip" -d "$ort_dir/tmp"
      # Zip layout: <pkg>-<version>/{lib,include}; flatten it.
      mv "$ort_dir/tmp/${ort_pkg}-${ONNXRUNTIME_VERSION}"/* "$ort_dir/"
      rm -rf "$ort_dir/tmp" "$ort_dir/pkg.zip"
    fi
    export SHERPA_ONNXRUNTIME_LIB_DIR="$ort_dir/lib"
    export SHERPA_ONNXRUNTIME_INCLUDE_DIR="$ort_dir/include"

    cmake -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
      -DSHERPA_ONNX_ENABLE_TTS=ON \
      -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON \
      -DSHERPA_ONNX_ENABLE_BINARY=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
      -DSHERPA_ONNX_ENABLE_TESTS=OFF \
      -DSHERPA_ONNX_ENABLE_CHECK=OFF \
      -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
      -DSHERPA_ONNX_ENABLE_JNI=OFF \
      -DSHERPA_ONNX_LINK_LIBSTDCPP_STATICALLY=OFF \
      -DSHERPA_ONNX_ENABLE_C_API=ON \
      -DCMAKE_INSTALL_PREFIX=./install \
      -DSHERPA_ONNX_ENABLE_RKNN=OFF \
      -DANDROID_ABI="$abi" \
      -DANDROID_PLATFORM=android-21 \
      "$@" \
      ..

    make -j4
    make install/strip
  )
}

copy_android() {
  local abi="$1" split_pkg="$2"
  local src="$SHERPA_DIR/build-android-$abi-self-contained/install/lib"
  require_file "$src/libsherpa-onnx-c-api.so"
  if [ -e "$src/libonnxruntime.so" ]; then
    die "$src contains libonnxruntime.so -- build is not self-contained (stale build dir? re-run with --clean)"
  fi

  # Verify there is no dynamic dependency on onnxruntime, if we can.
  local readelf=""
  for cand in "${ANDROID_NDK:-}/toolchains/llvm/prebuilt/"*/bin/llvm-readelf; do
    [ -x "$cand" ] && readelf="$cand" && break
  done
  [ -n "$readelf" ] || readelf="$(command -v llvm-readelf || command -v readelf || true)"
  if [ -n "$readelf" ]; then
    if "$readelf" -d "$src/libsherpa-onnx-c-api.so" | grep -q "libonnxruntime"; then
      "$readelf" -d "$src/libsherpa-onnx-c-api.so" >&2
      die "libsherpa-onnx-c-api.so ($abi) still dynamically depends on libonnxruntime.so"
    fi
  else
    warn "no readelf found -- cannot verify $abi .so has no libonnxruntime.so dependency"
  fi

  local dest
  for dest in \
    "$FLUTTER_DIR/$split_pkg/android/src/main/jniLibs/$abi" \
    "$FLUTTER_DIR/sherpa_onnx_android/android/src/main/jniLibs/$abi"; do
    log "Copying Android $abi libs -> ${dest#$SCRIPT_DIR/}"
    mkdir -p "$dest"
    rm -f "$dest"/*.so   # drop stale libs (incl. any old libonnxruntime.so), keep .gitkeep
    # Only the C API library: Dart FFI opens libsherpa-onnx-c-api.so, and
    # onnxruntime is already statically linked into it.
    cp -v "$src/libsherpa-onnx-c-api.so" "$dest/"
    require_file "$dest/libsherpa-onnx-c-api.so"
  done
}

if want android-arm64; then
  build_android arm64-v8a onnxruntime-android-arm64-v8a-static_lib -DSHERPA_ONNX_ENABLE_QNN=OFF
  copy_android arm64-v8a sherpa_onnx_android_arm64
fi

if want android-armv7; then
  build_android armeabi-v7a onnxruntime-android-armeabi-v7a-static_lib -DANDROID_ARM_NEON=ON
  copy_android armeabi-v7a sherpa_onnx_android_armeabi
fi

# ---------------------------------------------------------------------------
# Web (WASM; onnxruntime is always statically linked in)
# ---------------------------------------------------------------------------
if want web; then
  clean_dir build-wasm-simd-web
  # Deliberately not build-flutter-web-wasm.sh: it symlinks the JS wrappers
  # into assets/. Copy real files instead (as release-dart-package.yaml
  # does) so the plugin also works where symlinks are not preserved.
  run_build build-wasm-simd-web.sh

  src="$SHERPA_DIR/build-wasm-simd-web/install/bin/wasm/web"
  dst="$FLUTTER_DIR/sherpa_onnx_web/assets"
  require_file "$src/sherpa-onnx-wasm-web.js"
  require_file "$src/sherpa-onnx-wasm-web.wasm"
  log "Copying Web WASM assets -> ${dst#$SCRIPT_DIR/}"
  mkdir -p "$dst"
  cp -v "$src/sherpa-onnx-wasm-web.js"   "$dst/"
  cp -v "$src/sherpa-onnx-wasm-web.wasm" "$dst/"
  cp -v "$SHERPA_DIR/wasm/asr/sherpa-onnx-asr.js"                           "$dst/"
  cp -v "$SHERPA_DIR/wasm/tts/sherpa-onnx-tts.js"                           "$dst/"
  cp -v "$SHERPA_DIR/wasm/vad/sherpa-onnx-vad.js"                           "$dst/"
  cp -v "$SHERPA_DIR/wasm/kws/sherpa-onnx-kws.js"                           "$dst/"
  cp -v "$SHERPA_DIR/wasm/nodejs/sherpa-onnx-punctuation.js"                "$dst/"
  cp -v "$SHERPA_DIR/wasm/speaker-diarization/sherpa-onnx-speaker-diarization.js" "$dst/"
  cp -v "$SHERPA_DIR/wasm/speech-enhancement/sherpa-onnx-speech-enhancement.js"   "$dst/"
  for f in sherpa-onnx-wasm-web.js sherpa-onnx-wasm-web.wasm \
           sherpa-onnx-asr.js sherpa-onnx-tts.js sherpa-onnx-vad.js \
           sherpa-onnx-kws.js sherpa-onnx-punctuation.js \
           sherpa-onnx-speaker-diarization.js sherpa-onnx-speech-enhancement.js; do
    require_file "$dst/$f"
  done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "Done (self-contained, no separate onnxruntime to ship). Artifacts for: ${TARGETS[*]}"
want ios           && ls -ld "$FLUTTER_DIR/sherpa_onnx_ios/ios/sherpa_onnx_ios/SherpaOnnxC.xcframework"
want macos         && ls -ld "$FLUTTER_DIR/sherpa_onnx_macos/macos/sherpa_onnx_macos/sherpa-onnx.xcframework"
want android-arm64 && ls -lh "$FLUTTER_DIR/sherpa_onnx_android_arm64/android/src/main/jniLibs/arm64-v8a/"*.so
want android-armv7 && ls -lh "$FLUTTER_DIR/sherpa_onnx_android_armeabi/android/src/main/jniLibs/armeabi-v7a/"*.so
want web           && ls -lh "$FLUTTER_DIR/sherpa_onnx_web/assets/"
