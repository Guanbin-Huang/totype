# ToType iPhone personal build

Native iPhone app + offline typing/voice keyboard, iOS 17+. Build 3 adds a Chinese pinyin/English keyboard and keyboard-controlled dictation roundtrip. It is a local development build, not an upstream App Store release.

## Use
1. Add ToType in Settings > General > Keyboard > Keyboards. Local typing works without Full Access. Enable Full Access for shared voice requests/transcripts and opt-in vocabulary learning.
2. Type Chinese pinyin and choose a candidate (space selects the first candidate); use 中/EN for English and 123 for digits/punctuation. Partial-word selection preserves remaining pinyin. The globe changes keyboards. Return inserts a newline; it never invokes a chat Send button.
3. In the target app's ToType keyboard, tap 点击说话. The host starts its microphone/ASR session, then requests return to the detected source app. Speak there, then tap 停止并输入. A completed result inserts once only when the original document ID and surrounding-context fingerprint still match. Changed/unknown targets require explicit insertion.
4. 取消语音 blocks insertion immediately in the keyboard; the persisted cancel command also survives keyboard recreation. The host checks cancellation before publishing a result. Maximum voice session is 120 seconds.
5. Optional 10-second correction learning is off by default. Enable it only if desired. Stable replacements become local candidates; pure additions are ignored. Terms can be removed.

## Roundtrip implementation and evidence boundary

The keyboard detects its host via the MIT-licensed `getdictus/dictus-ios` implementation (revision recorded in source headers). This personal build uses private UIKit SPI. The host opens a fixed source-app resume scheme; successful URL acceptance alone does not prove same-chat restoration. Current supported return mappings are WeChat, WhatsApp, Telegram, Notes, Mail and Slack. An unresolved source displays manual-return guidance rather than guessing an app.

Normal host-only recording is cancelled on backgrounding. An explicitly keyboard-initiated session may continue background audio and can be stopped/cancelled from the keyboard. No automatic chat sending is implemented.

The device diagnostic `Documents/totype-status.json` is refreshed when the host appears or the user taps refresh. `voiceHandoff` reports a request ID, stage and match booleans, not transcript/context text. Real-device same-chat return, host resolution, microphone/background operation and input-context continuity remain acceptance gates even after a successful build.

## Offline typing

A read-only SQLite lexicon contains 65,125 entries from Apache-2.0 `rime/rime-pinyin-simp`, pinned to `0c6861ef7420ee780270ca6d993d18d4101049d0`. Source and license are in `Keyboard/Resources/`; regeneration/tests are in `scripts/mobile-keyboard/`. The lexicon is packaged in the extension; it is not a network service. The keyboard provides pinyin candidates/word-prefix composition, English, digits and punctuation. It does not claim the same prediction quality as commercial input methods.

## Credentials, privacy and latency

Doubao credentials remain in the host-only Keychain group; the keyboard only receives shared text/vocabulary access. No credential is bundled into this project or build. No extra LLM request, second ASR pass or synchronous 10-second learning delay is added. Terms feed the existing initial ASR frame. The vocabulary remains local to this phone; automatic Mac synchronization is not included.

## Build and tests

Generate with `xcodegen generate`, then build scheme `ToTypeMobile` for iPhone. Signing team/bundle IDs are in `project.yml`. Development provisioning expires and must be refreshed before its actual signed expiry.

From the repository root:

```sh
scripts/mobile-voice-tests/run.sh
scripts/mobile-keyboard/test.sh
scripts/mobile-keyboard/test_ui.sh
```

Voice tests compile the actual model/bridge/policy with controlled substitutes for external platform/ASR dependencies: 7 tests pass; the captured original model reproduces 5 failures using the same harness. Offline lexicon/composition and UIKit tests are separate from physical microphone/WeChat acceptance. See each test README/log for exact coverage.

## Resume prompt

```text
Continue ToType iOS build 3 in this checkout. First inspect current source, installed bundle version and device connection; reuse passing tests unless their inputs changed. Verify: Chinese/English keyboard typing, keyboard -> host microphone -> automatic same-WeChat-chat return -> stop -> insert once; cancel must insert nothing and changed chats must not receive old results. Do not send chat messages. Keep credentials private, preserve unrelated edits, and do not mark the goal complete until real-device evidence covers every gate.
```
