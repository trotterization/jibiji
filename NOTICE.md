# Third-party notices

## CC-CEDICT

`JIBIJI/Lexicon/CEDICT.tsv` is derived from **CC-CEDICT**, a community-maintained free Chinese–English dictionary published by MDBG.

- Source: <https://www.mdbg.net/chinese/dictionary?page=cc-cedict> (export `cedict_1_0_ts_utf-8_mdbg.zip`, 2026-11-20, 125,446 entries)
- Referenced work: CEDICT, Copyright (C) 1997, 1998 Paul Andrew Denisowski
- Licence: [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/)

Changes made: comments and Traditional-character headwords were removed, entries were de-duplicated and sorted, and glosses were joined with ` | ` (`scripts/build-lexicon.py`). Any redistribution of that table must keep this notice and the same licence. The dictionary is used only as an offline lookup: no entry leaves the device.

## jieba word list (frequencies)

The fourth column of `JIBIJI/Lexicon/CEDICT.tsv` (how common each word is, used only to rank words that are spelled the same) comes from the word list of **jieba**, <https://github.com/fxsjy/jieba> (`extra_dict/dict.txt.big`).

MIT License. Copyright (c) 2013 Sun Junyi.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
