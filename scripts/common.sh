#!/bin/bash
# Shared environment for local builds/tests. Source from a script in scripts/.
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_root="$project_root"
if [ -n "${EHK_XCODE_APP:-}" ]; then
  export DEVELOPER_DIR="$EHK_XCODE_APP/Contents/Developer"
elif [ -z "${DEVELOPER_DIR:-}" ]; then
  project_selected_xcode="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [ -d "$project_selected_xcode/Platforms" ]; then
    export DEVELOPER_DIR="$project_selected_xcode"
  elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo 'Full Xcode is required. Set EHK_XCODE_APP to your Xcode.app path.' >&2
    exit 1
  fi
fi
if [ ! -d "$DEVELOPER_DIR/Platforms" ]; then
  echo 'DEVELOPER_DIR must point to a full Xcode installation.' >&2
  exit 1
fi
project_build_root="${EHK_BUILD_DIR:-$project_root/build}"
mkdir -p "$project_build_root"
project_build_root="$(cd -- "$project_build_root" && pwd -P)"
mkdir -p "$project_build_root/tmp" "$project_build_root/logs" "$project_build_root/tests" "$project_build_root/ModuleCache"
export TMPDIR="$project_build_root/tmp/"
project_arch="$(uname -m)"
