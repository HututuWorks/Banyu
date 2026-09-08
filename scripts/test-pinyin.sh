#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
pinyin_out="$project_build_root/tests/pinyin"
mkdir -p "$pinyin_out"
pinyin_run="$(mktemp -d "$pinyin_out/run.XXXXXX")"
# Isolated synthetic dictionaries; never read or mutate the user's keyboard data.
trap 'rm -rf -- "$pinyin_run"' EXIT
native_sources=("$source_root/Keyboard/PinyinDecoder.mm" "$source_root"/Vendor/AOSPPinyin/jni/share/*.cpp)
project_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang++ -std=c++17 -fobjc-arc -O1 -g -fsanitize=address,undefined \
  -isysroot "$project_sdk" -framework Foundation "${native_sources[@]}" \
  "$source_root/Vendor/AOSPPinyin/tests/bridge_smoke.mm" -o "$pinyin_out/bridge-smoke"
"$pinyin_out/bridge-smoke" "$source_root/Resources/dict_pinyin.dat" "$pinyin_run/bridge.dict"
xcrun clang++ -std=c++17 -fobjc-arc -O1 -g -fsanitize=address,undefined \
  -isysroot "$project_sdk" -framework Foundation -dynamiclib "${native_sources[@]}" \
  -install_name @rpath/libPinyinBridge.dylib -o "$pinyin_out/libPinyinBridge.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -sanitize=address \
  -target "${project_arch}-apple-macos26.0" -sdk "$project_sdk" \
  -module-cache-path "$project_build_root/ModuleCache" \
  -import-objc-header "$source_root/Keyboard/PinyinDecoder.h" \
  "$source_root/Keyboard/NineKeyPinyinDecoder.swift" \
  "$source_root/Vendor/AOSPPinyin/tests/nine_key_smoke.swift" \
  -L "$pinyin_out" -lPinyinBridge -Xlinker -rpath -Xlinker "$pinyin_out" \
  -o "$pinyin_out/nine-key-smoke"
"$pinyin_out/nine-key-smoke" "$source_root/Resources/dict_pinyin.dat" "$pinyin_run/t9.dict"
