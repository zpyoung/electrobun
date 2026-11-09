#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: macOS frame navigation rules native test requires Darwin"
  exit 0
fi

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d -t electrobun-frame-navigation-rules-test.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_binary="$test_dir/frame-navigation-rules-test"

xcrun clang++ \
  -std=c++20 \
  -fobjc-arc \
  -fblocks \
  -framework Cocoa \
  -framework WebKit \
  "$package_dir/src/native/macos/frame_navigation_rules.test.mm" \
  -o "$test_binary"

"$test_binary"
