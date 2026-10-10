# Offline pinyin dictionary

Source: https://github.com/rime/rime-pinyin-simp
Locked revision: 0c6861ef7420ee780270ca6d993d18d4101049d0
Input: pinyin_simp.dict.yaml, derived by Rime from Android Open Source Project PinyinIME.
License: Apache-2.0; full upstream license is Pinyin-LICENSE.txt.
The upstream dictionary retains its original authorship/header in scripts/mobile-keyboard/pinyin_simp.dict.yaml.
Modification: normalize syllable spellings and store original word weights in indexed, read-only SQLite.
Build: python3 scripts/mobile-keyboard/build_lexicon.py (checks pinned input SHA-256).
No model, network, credential, or Full Access permission is used by the typing engine.
