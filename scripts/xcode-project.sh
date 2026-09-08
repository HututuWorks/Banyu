#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
project_action="${1:-help}"
if [ "$#" -gt 0 ]; then shift; fi
case "$project_action" in
  help|--help|-h)
    cat <<'USAGE'
Usage: scripts/xcode-project.sh <command> [xcodebuild arguments]
  version              Show selected Xcode version
  check                Check Xcode first-launch setup
  sdks                 List installed SDKs
  build-device [args]  Build app and both keyboard extensions for iPhone
  build [args]         Run xcodebuild with repository-local DerivedData

Configuration: EHK_CONFIGURATION=Debug|Release (default Debug)
Optional: EHK_XCODE_APP=/path/to/Xcode.app, EHK_BUILD_DIR=/path/to/build
Unsigned build: EHK_CONFIGURATION=Release scripts/xcode-project.sh build-device CODE_SIGNING_ALLOWED=NO build
Signed build: copy Config/Local.xcconfig.example to Config/Local.xcconfig and set your team.
USAGE
    exit 0 ;;
  version) exec /usr/bin/xcodebuild -version "$@" ;;
  check) exec /usr/bin/xcodebuild -checkFirstLaunchStatus "$@" ;;
  sdks) exec /usr/bin/xcodebuild -showsdks "$@" ;;
  build-device)
    project_configuration="${EHK_CONFIGURATION:-Debug}"
    case "$project_configuration" in Debug|Release) ;; *) echo 'Invalid EHK_CONFIGURATION' >&2; exit 2 ;; esac
    exec /usr/bin/xcodebuild \
      -project "$project_root/EnglishHintKeyboard.xcodeproj" \
      -target EnglishHintKeyboard -configuration "$project_configuration" -sdk iphoneos \
      SYMROOT="$project_build_root/Products" OBJROOT="$project_build_root/Intermediates" \
      SHARED_PRECOMPS_DIR="$project_build_root/PrecompiledHeaders" \
      CLANG_MODULE_CACHE_PATH="$project_build_root/ModuleCache" "$@" ;;
  build)
    exec /usr/bin/xcodebuild -derivedDataPath "$project_build_root/DerivedData" \
      -clonedSourcePackagesDirPath "$project_build_root/SourcePackages" \
      -packageCachePath "$project_build_root/PackageCache" "$@" ;;
  *) echo "Unknown command: $project_action" >&2; exit 2 ;;
esac
