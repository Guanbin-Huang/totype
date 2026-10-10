#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/totype-startup-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
src = (root/'VerbatimVoiceMobile/Keyboard/KeyboardViewController.swift').read_text()
start = src.index('    private func refreshVoice() {')
end = src.index('    @objc private func nextKeyboard()', start)
method = src[start:end]
wrapper = '''import Foundation
@MainActor final class StartupKeyboard {
    let hasFullAccess = true
    let statusLabel = StartupLabel()
    let stopButton = StartupButton(), cancelButton = StartupButton(), insertButton = StartupButton()
    var voiceLauncher: StartupLauncher? = StartupLauncher()
    let typingView = StartupTyping(), textDocumentProxy = StartupProxy()
    var voiceRequest: MobileVoiceRequest?
    var cancelledRequestID: UUID?, attemptedInsertion: UUID?
    var lastVoiceStatus: String?
    var pending: MobilePendingTranscript?
    func insertLatest() { fatalError("unexpected insertion in startup fixture") }
    func recordHandoff(_ request: MobileVoiceRequest, stage: String, documentMatches: Bool? = nil, contextMatches: Bool? = nil) throws {}
    func tick() { refreshVoice() }
'''
(tmp/'StartupKeyboard.swift').write_text(wrapper + method + '}\n')
PY
swiftc -swift-version 5 -parse-as-library \
  "$ROOT/scripts/mobile-voice-tests/Stubs.swift" \
  "$ROOT/VerbatimVoiceMobile/Shared/MobileVoiceBridge.swift" \
  "$ROOT/VerbatimVoiceMobile/Shared/MobileVoiceHandoffPolicy.swift" \
  "$TMP/StartupKeyboard.swift" "$ROOT/scripts/mobile-voice-tests/startup-expiry.swift" -o "$TMP/startup-test"
"$TMP/startup-test"
