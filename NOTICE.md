# Third-party notices

## CC-CEDICT

`JIBIJI/Lexicon/CEDICT.tsv` is derived from **CC-CEDICT**, a community-maintained free Chinese–English dictionary published by MDBG.

- Source: <https://www.mdbg.net/chinese/dictionary?page=cc-cedict> (export `cedict_1_0_ts_utf-8_mdbg.zip`, 2026-11-20, 125,446 entries)
- Referenced work: CEDICT, Copyright (C) 1997, 1998 Paul Andrew Denisowski
- Licence: [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/)

Changes made: comments and Traditional-character headwords were removed, entries were de-duplicated and sorted, and glosses were joined with ` | ` (`scripts/build-lexicon.py`). Any redistribution of that table must keep this notice and the same licence. The dictionary is used only as an offline lookup: no entry leaves the device.
