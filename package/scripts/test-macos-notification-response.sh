#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: macOS notification response native test requires Darwin"
  exit 0
fi

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_binary="$(mktemp -t electrobun-notification-response-test.XXXXXX)"
trap 'rm -f "$test_binary"' EXIT

xcrun clang++ \
  -std=c++20 \
  -fobjc-arc \
  -fblocks \
  -framework Foundation \
  -framework UserNotifications \
  "$package_dir/src/native/macos/notification_response.test.mm" \
  -o "$test_binary"

"$test_binary"
