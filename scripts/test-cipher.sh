#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library -swift-version 5 -module-cache-path "$TEST_DIR/cache" \
  VaultTypes.swift VaultCipher.swift Tests/CipherTests.swift -o "$TEST_DIR/cipher-tests"
"$TEST_DIR/cipher-tests"
