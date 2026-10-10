#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/totype-voice-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" "${1:-$ROOT/VerbatimVoiceMobile/Host/MobileDictationModel.swift}" <<'PY'
from pathlib import Path
import sys
root, temp, model = map(Path, sys.argv[1:])
source = model.read_text()
for module in ['SwiftUI', 'AVFoundation', 'UIKit']:
    source = source.replace('import ' + module + '\n', '')
(temp / 'MobileDictationModel.swift').write_text('import Foundation\nimport Combine\n' + source)
# The bridge uses a synchronous in-memory keychain stub. No bridge logic is changed.
(temp / 'MobileVoiceBridge.swift').write_text((root / 'VerbatimVoiceMobile/Shared/MobileVoiceBridge.swift').read_text())
PY
swiftc -swift-version 5 -parse-as-library \
  "$ROOT/scripts/mobile-voice-tests/Stubs.swift" \
  "$TMP/MobileDictationModel.swift" "$TMP/MobileVoiceBridge.swift" \
  "$ROOT/VerbatimVoiceMobile/Shared/MobileVoiceHandoffPolicy.swift" \
  "$ROOT/scripts/mobile-voice-tests/Tests.swift" -o "$TMP/tests"
"$TMP/tests"
