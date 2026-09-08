#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
project_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  -target ${project_arch}-apple-macos26.0 -sdk "$project_sdk" \
  -D APPLE_PROVIDER_TESTS \
  -module-cache-path "$project_build_root/ModuleCache" \
  "$source_root/Shared/LiveHintCore.swift" \
  "$source_root/Shared/AppleInstalledTranslator.swift" \
  "$source_root/Tests/LiveHintCoreTests.swift" \
  -o "$project_build_root/tests/LiveHintCoreTests"
"$project_build_root/tests/LiveHintCoreTests"
