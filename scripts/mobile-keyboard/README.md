# ToType offline typing keyboard

## Integration

Add `KeyboardTypingView` to the keyboard controller at height 250 points (voice controls excluded).
Wire `onInsertText` to `textDocumentProxy.insertText`, `onDeleteBackward` to
`textDocumentProxy.deleteBackward`, and `onNextKeyboard` to `advanceToNextInputMode`.
Call `commitComposition()` before starting voice input. Call `discardComposition()`
when the document identity changes to drop pending spelling without inserting it. `hasComposition` identifies
uncommitted local spelling. Bundle `Keyboard/Resources/pinyin.sqlite3` in the keyboard
extension, and link the system `SQLite3` module. The typing view uses no network or
App Group data and works without Full Access.

The candidate strip supports local spelling, exact phrases, prefix phrase selection,
partial spellings, explicit apostrophes, and a raw spelling candidate. Choosing a
prefix consumes only that prefix; remaining spelling stays available for the next
candidate. Space selects the top candidate when composing, otherwise inserts space.
Return flushes all remaining composition and inserts newline. Chinese shift switches
to one-letter uppercase English; English shift uppercases one letter. Globe flushes
composition before invoking the next keyboard callback. Long-press delete repeats.

A missing/broken dictionary is shown explicitly in the composition strip; letters
remain available as raw spelling. The shipped 65,125-entry source is Apache-2.0
Rime `pinyin-simp` at revision `0c6861ef7420ee780270ca6d993d18d4101049d0`.
`Pinyin-SOURCE.md` and `Pinyin-LICENSE.txt` accompany the resource.

## Rebuild and test

```
python3 scripts/mobile-keyboard/build_lexicon.py
scripts/mobile-keyboard/test.sh
scripts/mobile-keyboard/test_ui.sh
```

`test.sh` compiles the actual lexicon/composition source into a macOS executable and
then typechecks both actual files for arm64 iOS 17. `test_ui.sh` compiles a real UIKit
app and uses a disposable iOS 26.5 iPhone 17 Pro simulator to press actual UIButton
controls. It leaves existing simulators alone and deletes its own on exit.

Tests cover common phrases, multiword prefix selection, explicit syllable separators,
composition delete/raw commit, abbreviations, input bounds, Chinese candidate UI,
English case, numbers, punctuation, symbol switching, space, return and globe callbacks.
Simulator tests are not physical-device keyboard/voice-roundtrip proof; controller
integration and the actual target app still require the main task's device test.
