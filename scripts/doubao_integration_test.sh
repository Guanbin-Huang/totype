#!/usr/bin/env bash
# Offline settings/routing/profile checks. No credentials, private fixtures or network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SDK_PATH="${VERBATIM_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_DIR="$ROOT/.build/doubao-integration-test"
mkdir -p "$BUILD_DIR/module-cache"
swiftc -module-cache-path "$BUILD_DIR/module-cache" -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 -parse-as-library \
  VerbatimVoiceCore/Sources/VerbatimCore/*.swift \
  VerbatimVoice/Models/ProviderContextCompiler.swift \
  VerbatimVoice/Models/TranscriptionModels.swift \
  VerbatimVoice/App/AppIdentity.swift \
  VerbatimVoice/App/AppSettings.swift \
  VerbatimVoice/App/AppSettingsProfile.swift \
  scripts/doubao-integration-test/main.swift \
  -o "$BUILD_DIR/doubao-integration-test"
"$BUILD_DIR/doubao-integration-test"
swiftc -frontend -parse \
  VerbatimVoice/App/AppSettings.swift VerbatimVoice/App/AppModel.swift \
  VerbatimVoice/UI/SettingsView.swift VerbatimVoice/UI/MenuBarView.swift \
  VerbatimVoice/UI/OnboardingView.swift
plutil -lint VerbatimVoice.xcodeproj/project.pbxproj
