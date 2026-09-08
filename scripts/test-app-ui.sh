#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
python3 "$source_root/Tests/AppUI/build_preview.py" \
  --root "$source_root" --output "$project_build_root/app-ui" --arch "$project_arch"
