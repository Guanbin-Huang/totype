#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/totype-mobile-keyboard-ui"
APP="$WORK/KeyboardHarness.app"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator -sdk "$SDK" "$ROOT/VerbatimVoiceMobile/Keyboard/PinyinLexicon.swift" "$ROOT/VerbatimVoiceMobile/Keyboard/KeyboardTypingView.swift" "$ROOT/scripts/mobile-keyboard/UIKitHarness.swift" -o "$APP/KeyboardHarness"
cp "$ROOT/VerbatimVoiceMobile/Keyboard/Resources/pinyin.sqlite3" "$APP/"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.peter.totype.keyboardharness</string>
<key>CFBundleName</key><string>KeyboardHarness</string>
<key>CFBundleExecutable</key><string>KeyboardHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
DEVICE="$(xcrun simctl create ToTypeKeyboardIsolatedTest com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5)"
trap 'xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1; xcrun simctl delete "$DEVICE" >/dev/null 2>&1' EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.peter.totype.keyboardharness
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" com.peter.totype.keyboardharness data)"
for attempt in $(seq 1 20); do
    if [[ -f "$CONTAINER/Documents/results.txt" ]]; then
        cat "$CONTAINER/Documents/results.txt"
        printf '\n'
        exit 0
    fi
    sleep 1
done
printf 'FAIL UIKit harness did not produce results\n' >&2
exit 1
