#!/usr/bin/env python3
"""Builds JIBIJI/Lexicon/CEDICT.tsv from the official CC-CEDICT export.

Usage: scripts/build-lexicon.py path/to/cedict_ts.u8 [path/to/jieba_dict.txt]
Download: https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.zip
Word frequencies (optional, MIT): https://raw.githubusercontent.com/fxsjy/jieba/master/extra_dict/dict.txt.big
CC-CEDICT is licensed CC BY-SA 4.0 and the frequency list MIT (see NOTICE.md).
Output columns: simplified, numbered pinyin, glosses joined by " | ", corpus frequency (0 when unlisted).
Only the simplified headword is kept (the app writes Simplified Chinese). Entries are sorted so builds are reproducible.
"""
import re, sys

LINE = re.compile(r"^(\S+) (\S+) \[([^\]]+)\] /(.+)/\s*$")

def load_frequencies(path):
    freq = {}
    if not path:
        return freq
    for raw in open(path, encoding="utf-8"):
        parts = raw.split()
        if len(parts) >= 2 and parts[1].isdigit():
            freq[parts[0]] = max(freq.get(parts[0], 0), int(parts[1]))
    return freq

def main(path, freq_path=None):
    freq = load_frequencies(freq_path)
    rows = set()
    for raw in open(path, encoding="utf-8"):
        if raw.startswith("#"):
            continue
        m = LINE.match(raw)
        if not m:
            continue
        _trad, simp, pinyin, glosses = m.groups()
        glosses = " | ".join(g.strip() for g in glosses.split("/") if g.strip())
        if "\t" in simp + pinyin + glosses:
            continue
        rows.add((simp, pinyin, glosses))
    out = "JIBIJI/Lexicon/CEDICT.tsv"
    with open(out, "w", encoding="utf-8") as f:
        for simp, pinyin, glosses in sorted(rows):
            f.write(f"{simp}\t{pinyin}\t{glosses}\t{freq.get(simp, 0)}\n")
    print(f"{len(rows)} entries -> {out}")

main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
