#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: macOS webview navigation native test requires Darwin"
  exit 0
fi

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d -t electrobun-webview-navigation-test.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_binary="$test_dir/webview-navigation-test"

xcrun clang++ \
  -std=c++20 \
  -fobjc-arc \
  -fblocks \
  -framework Cocoa \
  -framework WebKit \
  "$package_dir/src/native/macos/webview_navigation.test.mm" \
  -o "$test_binary"

"$test_binary"
