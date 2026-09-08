#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
test_output="${EHK_TEST_OUTPUT:-$project_build_root/keyboard-lifecycle}"
project_sdk="$(xcrun --sdk macosx --show-sdk-path)"
test_app="$test_output/KeyboardLifecycleTests.app"
mkdir -p "$test_output/ModuleCache" "$test_app/Contents/MacOS"
sed 's/final class KeyboardViewController: UIInputViewController/class KeyboardViewController: UIInputViewController/' \
  "$source_root/Keyboard/KeyboardViewController.swift" > "$test_output/ControllerWithTests.swift"
cat "$source_root/Tests/KeyboardLifecycleTests.swift" >> "$test_output/ControllerWithTests.swift"
cat > "$test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KeyboardLifecycleTests</string>
<key>CFBundleIdentifier</key><string>local.banyu.KeyboardLifecycleTests</string>
<key>CFBundleName</key><string>KeyboardLifecycleTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  -target "$(uname -m)-apple-ios26.0-macabi" -sdk "$project_sdk" \
  -module-cache-path "$test_output/ModuleCache" \
  -F "$project_sdk/System/iOSSupport/System/Library/Frameworks" -framework UIKit \
  "$source_root/Shared/LiveHintCore.swift" \
  "$source_root/Shared/HintReplacement.swift" \
  "$source_root/Shared/SentenceAnalysis.swift" \
  "$source_root/Shared/SentenceAnalysisSession.swift" \
  "$source_root/Shared/KeyboardStudyLayout.swift" \
  "$source_root/Shared/QwenSpeechSynthesizer.swift" \
  "$source_root/Shared/SpeechPlaybackSession.swift" \
  "$source_root/Keyboard/KeyboardAudioPlayer.swift" \
  "$source_root/Keyboard/KeyboardSurface.swift" \
  "$source_root/Keyboard/SentenceAnalysisPanel.swift" \
  "$source_root/Keyboard/NineKeyPinyinDecoder.swift" \
  "$source_root/Tests/Support/KeyboardLifecycleStubs.swift" \
  "$test_output/ControllerWithTests.swift" \
  -o "$test_app/Contents/MacOS/KeyboardLifecycleTests"
"$test_app/Contents/MacOS/KeyboardLifecycleTests"
