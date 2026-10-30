#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: macOS website data store native test requires Darwin"
  exit 0
fi

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/electrobun-website-data-store.XXXXXX")"
# WebKit keeps an unbundled tool's data under its executable name, so a unique
# name keeps this test away from every other app's website data.
test_name="electrobun-website-data-store-test-$(basename "$test_dir" | cut -d. -f2)"
cleanup() {
  rm -rf "$test_dir" \
    "$HOME/Library/WebKit/$test_name" \
    "$HOME/Library/HTTPStorages/$test_name" \
    "$HOME/Library/Caches/$test_name"
}
trap cleanup EXIT

xcrun --sdk macosx clang++ \
  -std=c++20 \
  -fobjc-arc \
  -fblocks \
  -framework Cocoa \
  -framework WebKit \
  "$package_dir/src/native/macos/website_data_store.test.mm" \
  -o "$test_dir/$test_name"

"$test_dir/$test_name"
