#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/short-model-routing.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete "$ROOT/VerbatimVoice/Providers/ChatTextPolisher.swift" "$ROOT/scripts/short-model-routing-test/main.swift" -o "$BUILD/test"
"$BUILD/test"
