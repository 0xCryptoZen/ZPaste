#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Models.swift ClipboardPolicy.swift HistoryMaintenance.swift Tests/StorageTests.swift \
  -o "$TEST_DIR/storage-tests"
"$TEST_DIR/storage-tests"
