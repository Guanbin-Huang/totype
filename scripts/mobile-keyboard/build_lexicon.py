#!/usr/bin/env python3
"""Build the locked Apache-2.0 Rime PinyinIME-derived dictionary into SQLite."""
import hashlib
import pathlib
import sqlite3

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = pathlib.Path(__file__).with_name('pinyin_simp.dict.yaml')
OUTPUT = ROOT / 'VerbatimVoiceMobile/Keyboard/Resources/pinyin.sqlite3'
EXPECTED_SHA256 = 'e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b'
raw = SOURCE.read_bytes()
actual = hashlib.sha256(raw).hexdigest()
if actual != EXPECTED_SHA256:
    raise SystemExit(f'Source checksum mismatch: {actual}')
OUTPUT.unlink(missing_ok=True)
connection = sqlite3.connect(OUTPUT)
connection.executescript('''
PRAGMA page_size=4096;
CREATE TABLE entries(spelling TEXT NOT NULL, syllables TEXT NOT NULL, text TEXT NOT NULL, weight INTEGER NOT NULL);
''')
entries = []
for line in raw.decode().splitlines():
    fields = line.split('\t')
    if len(fields) < 3:
        continue
    word, syllables, weight = fields[:3]
    spelling = syllables.replace(' ', '').lower()
    if not spelling.isascii() or not spelling.isalpha():
        continue
    entries.append((spelling, syllables.replace(' ', "'"), word, int(weight)))
connection.executemany('INSERT INTO entries VALUES (?,?,?,?)', entries)
connection.executescript('CREATE INDEX spelling_weight ON entries(spelling, weight DESC); PRAGMA user_version=1;')
connection.commit()
connection.execute('VACUUM')
connection.close()
print(f'PASS entries={len(entries)} bytes={OUTPUT.stat().st_size} source_sha256={actual}')
