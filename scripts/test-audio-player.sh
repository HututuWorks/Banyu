#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
project_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  -target "${project_arch}-apple-ios26.0-macabi" -sdk "$project_sdk" \
  -module-cache-path "$project_build_root/ModuleCache" \
  -F "$project_sdk/System/iOSSupport/System/Library/Frameworks" \
  "$source_root/Shared/QwenSpeechSynthesizer.swift" \
  "$source_root/Shared/SpeechPlaybackSession.swift" \
  "$source_root/Keyboard/KeyboardAudioPlayer.swift" \
  "$source_root/Tests/KeyboardAudioPlayerTests.swift" \
  -o "$project_build_root/tests/KeyboardAudioPlayerTests"
"$project_build_root/tests/KeyboardAudioPlayerTests"
