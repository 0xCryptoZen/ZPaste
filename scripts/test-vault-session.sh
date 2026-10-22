#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
for source in *.swift; do
  if [[ "$source" != "ZPasteApp.swift" ]]; then SOURCES+=("$source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$TEST_DIR/cache" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "${SOURCES[@]}" Tests/VaultSessionTests.swift -o "$TEST_DIR/vault-session-tests"
"$TEST_DIR/vault-session-tests"
