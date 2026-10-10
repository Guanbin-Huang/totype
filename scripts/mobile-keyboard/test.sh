#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/totype-mobile-keyboard-tests"
mkdir -p "$WORK"
swiftc "$ROOT/VerbatimVoiceMobile/Keyboard/PinyinLexicon.swift" "$ROOT/scripts/mobile-keyboard/main.swift" -o "$WORK/pinyin-tests"
"$WORK/pinyin-tests" "$ROOT/VerbatimVoiceMobile/Keyboard/Resources/pinyin.sqlite3"
xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios17.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" "$ROOT/VerbatimVoiceMobile/Keyboard/PinyinLexicon.swift" "$ROOT/VerbatimVoiceMobile/Keyboard/KeyboardTypingView.swift"
printf 'PASS iOS UIKit source typecheck\n'
