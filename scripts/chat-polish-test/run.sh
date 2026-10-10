#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/lib/env.sh"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/chat-polish-test.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -sdk "$SDK_PATH" "$ROOT/VerbatimVoice/Providers/ChatTextPolisher.swift" "$ROOT/scripts/chat-polish-test/main.swift" -o "$BUILD/chat-polish-test"
"$BUILD/chat-polish-test" "$@"
