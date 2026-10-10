# Mobile voice regression harness

Run from the repository root:

```sh
scripts/mobile-voice-tests/run.sh
```

An optional first argument selects a different **model** source for a counterexample run. The shared bridge and policy always come from the current checkout:

```sh
scripts/mobile-voice-tests/run.sh /absolute/path/to/original/MobileDictationModel.swift
```

The runner compiles the real `MobileDictationModel.swift` after removing only its SwiftUI, AVFoundation and UIKit imports and adding Foundation/Combine. It compiles the real `MobileVoiceBridge.swift` and `MobileVoiceHandoffPolicy.swift` unchanged. Production methods, access control and state transitions are not copied or replaced. Temporary compilation products are removed on exit.

`Stubs.swift` replaces external audio, permission, ASR, application/background-task and storage dependencies. Controlled continuations pause provider cancellation and finalization, so tests explicitly release old/new tasks in the problematic order. Model methods execute on MainActor. Bridge JSON serialization/readback is real; the keychain backing is an in-memory map and does not touch credentials. The provider is a MainActor async stub rather than a network actor; these tests establish model suspension-boundary behavior, not transport scheduling or device functionality.

## Results, 2026-10-03

Current production source: `TESTS=7 PASS=7 FAIL=0`, exit 0 (`modified.log`).

Original model from `/Users/peter/Documents/Codex/2026-10-03/123/work/totype-resume/original/VerbatimVoiceMobile/Host/MobileDictationModel.swift` combined with **current bridge/policy**: `TESTS=7 PASS=2 FAIL=5`, exit 1 (`baseline.log`, expected counterexample). This comparison isolates model changes; it does not claim to test the original policy API, which lacked a cancellation command parameter.

Covered cases:

- Repeated cancellation reaches the provider once; start is blocked while cancel awaits and permitted after cleanup.
- Old start, sender and finalize cleanup resumes after a new bridged session starts, without changing its phase/request or deactivating its audio.
- A saved cancellation command arriving before the final result prevents publishing pending text.
- A late final result after cancellation cannot publish or change a newer session.
- JSON-reloaded cancel commands reject auto-insertion even when status is completed; normal completion remains allowed, unrelated commands do not cancel, changed document identity is rejected.

Still requires real iPhone/WeChat validation: microphone authorization/capture, background audio and finalization lifetime, private host-app resolution, URL return to the same chat, keyboard extension recreation and documentIdentifier continuity, context availability timing, native keychain access, UI insertion once-only behavior and tap-cancel versus timer refresh scheduling.
