#!/usr/bin/env python3
"""Builds JIBIJI/Lexicon/CEDICT.tsv from the official CC-CEDICT export.

Usage: scripts/build-lexicon.py path/to/cedict_ts.u8
Download: https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.zip
CC-CEDICT is licensed CC BY-SA 4.0 (see NOTICE.md). Output columns: simplified, numbered pinyin, glosses joined by " | ".
Only the simplified headword is kept (the app writes Simplified Chinese). Entries are sorted so builds are reproducible.
"""
import re, sys

LINE = re.compile(r"^(\S+) (\S+) \[([^\]]+)\] /(.+)/\s*$")

def main(path):
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
            f.write(f"{simp}\t{pinyin}\t{glosses}\n")
    print(f"{len(rows)} entries -> {out}")

main(sys.argv[1])
