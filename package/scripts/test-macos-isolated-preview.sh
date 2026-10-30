#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: macOS isolated preview native test requires Darwin"
  exit 0
fi

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_binary="$(mktemp -t electrobun-isolated-preview-test.XXXXXX)"
trap 'rm -f "$test_binary"' EXIT

xcrun clang++ \
  -std=c++20 \
  -fobjc-arc \
  -fblocks \
  -mmacosx-version-min=14.0 \
  -framework Cocoa \
  -framework WebKit \
  "$package_dir/src/native/macos/isolated_preview.test.mm" \
  -o "$test_binary"

"$test_binary"
