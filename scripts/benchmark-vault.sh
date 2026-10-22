#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -O -parse-as-library -swift-version 5 -module-cache-path "$TEST_DIR/cache" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Models.swift Store.swift VaultTypes.swift VaultCipher.swift VaultRecord.swift \
  VaultRepository.swift VaultMaintenance.swift VaultMigration.swift Tests/VaultBenchmarks.swift \
  -o "$TEST_DIR/vault-benchmarks"
"$TEST_DIR/vault-benchmarks"
