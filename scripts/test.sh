#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/common.sh"
suites=(core settings qwen speech-service speech-playback replacement analysis analysis-session study-layout pinyin)
case "${1:-}" in
  "") ;;
  --ui) suites+=(keyboard-lifecycle speech-surface app-ui) ;;
  *) echo 'Usage: scripts/test.sh [--ui]' >&2; exit 2 ;;
esac
for suite in "${suites[@]}"; do
  echo "Running $suite tests"
  "$script_dir/test-$suite.sh" > "$project_build_root/logs/test-$suite.log" 2>&1 || {
    cat "$project_build_root/logs/test-$suite.log"
    exit 1
  }
  tail -n 1 "$project_build_root/logs/test-$suite.log"
done
printf 'All local test suites passed. No live translation API requests were used.\n'
