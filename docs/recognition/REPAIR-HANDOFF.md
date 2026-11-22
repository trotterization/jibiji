# Recognition repair: handoff

Supersedes the "Next repair assignment" in `HANDOFF.md`. Design: `repair-flow.md`.

## State

| Item | Value |
|---|---|
| Branch | `task/recognition-repair` (from `d28b745` = PR #25 stage 3 + PR #27 docs) |
| Draft PR | https://github.com/trotterization/jibiji/pull/28 (base: PR #25's branch; nothing merged) |
| Commit | see the PR head. The installed Debug build stamp shows the short SHA. |
| Independent review | Fresh read-only reviewer found: short real English wrongly rejected as misfiled Pinyin; unresolved English could still yield a dictionary-gloss card; text-accepted older notes could stop matching; loose gloss-substring matching. All fixed with tests. Remaining, not fixed: proper nouns/abbreviations/accented loanwords fail the English spell check and become `unresolved` (safe, user edits); the spell check runs through the main thread (cached; no deadlock seen); simulator-only `isEnglish` tests depend on the device spell-check dictionary. |
| Tests | Full Simulator suite: 282 passed, 1 known Simulator-only issue (Chinese stroke recognition is not available in the Simulator). Injected readers and replayed device readings; not general handwriting accuracy. If the Simulator test launch hangs, `xcrun simctl shutdown all` and run `test-without-building`. |
| Installed | Signed Debug build installed over the existing app via devicectl; data untouched. Free-account profiles expire after 7 days: reinstall needs Xcode signed in and the profile trusted on the iPad. |
| Not included | PR #26 stage-4 records (unvalidated; not merged, not deployed) |
| Build stamp | Debug: bottom-right of the Home screen and the top of "Check recognition" show `build <git short SHA>` plus flags |

## What changed

- `PinyinValidator` / `FieldValidation`: Pinyin must split into real syllables with tone marks only on vowels; garbled-with-diacritics words (`hňo`) are "malformed Pinyin", never English.
- `NoteEvidence` + `FieldResolver`: every reading (PencilKit / Vision / Paddle, at cell, field and whole-note scope) is retained, then resolved into Hanzi / Pinyin / English with `confirmed / tentative / unresolved / absent` statuses. Only validated text enters a field. Lower-ranked recognizer guesses and rejected readings are `diagnostics` only.
- `NoteGrouping`: Pinyin with a word space (`hǎo | xiang`) is joined into one field; Latin right of a Hanzi that is one edit from its romanization (`ho`) is filed as Pinyin, not English.
- `PencilInkLineReader`: one evidence collector for Suggest and Cards (same reader, same mode). `HanziPrefixFallback` is no longer in the grouped path: whole-note readings supply that context.
- Suggest: the "readings fallback" is removed. Proposals come only from `StarterVocabulary` on the resolved text. Unresolved fields produce a plain message.
- Cards: `FlashcardExtractor.extract(from: RecognizedLine)` builds term cards from the resolved fields; accepted notes still override.
- Tests changed because behaviour was removed on purpose: tests that expected raw OCR alternatives as candidates now expect none.

## Evidence

- Simulator unit suite: see the PR for the final counts (all green at the last checkpoint, one known Simulator-only expected failure).
- Real saved ink (`好 hǎo xiang`, private, local only): geometry now yields **one** note covering all 15 strokes with `xiang` joined to its Pinyin field. In the Simulator the real engines still do not read `hǎo` (Vision: `好子 nho xiang`; Paddle: `好 ho xiang` / `hǔo` / `hǐo`), so the resolver leaves Pinyin unresolved or tentative instead of inventing it. Simulator PencilKit has no Chinese. **Only the iPad's PencilKit can show the real outcome.**
- Passing injected-reader tests is not handwriting accuracy.

## Not done / limits

- No general dictionary or semantic AI exists. Options are in `repair-flow.md`; none is added.
- Field-scoped ink correction, per-note records (PR #26) and persistence of skipped suggestions are untouched.
- Engine engines disagree on real ink; the status model reports that rather than hiding it.

## Physical iPad findings (page 6, `好 hǎo xiang`)

- **No hang.** "Suggest just loads" was not a hang. A Debug step log (`DebugTrace`, written to `Documents/trace.log`, DEBUG only) showed Suggest finishing in about 2 s. It then showed a small grey message at the top-right, easy to miss: "Pinyin could not be read reliably".
- **Cause of the unreadable Pinyin.** On the iPad the Paddle mobile model's plain best reading is `hǎo xiang` (what "Run Pinyin OCR by line" shows). Suggest used only the beam-search readings, whose top string was `hǔo xiang`. The correct reading was a lower-ranked alternate, which is diagnostic only. Fix: `PencilInkLineReader.evidence` now adds the plain reading first, then the beam guesses as alternates.
- **Result on the iPad:** the note resolves to `好 hǎo xiang`, one suggestion chip appears (像 / "to seem like; to look like"), "Save as note" works, and the cards show the approved English.
- Also removed: the main-thread hop in the spell check (replaced by a lock-protected `UITextChecker`). It was not the cause of the symptom.
- Not yet verified on the iPad: force-quit reopen, undo, export, and ink preserved after Replace.

## Limits that remain

- No AI. The 8 curated entries come first, then an offline dictionary (below). The dictionary is CC-CEDICT plus a word-frequency column (jieba, MIT); it has no HSK levels or example sentences.
- Proper nouns and loanwords fail the English spell check and become `unresolved` (safe; the student edits).
- One page and one ink sample were verified on the iPad. Handwriting accuracy in general is unproven.
- The "no suggestion" message is small and at the top-right; making it more visible is a UI change not made here.

## Dictionary and repair (added after the first iPad pass)

- **CC-CEDICT** (CC BY-SA 4.0; `NOTICE.md`) is bundled as `JIBIJI/Lexicon/CEDICT.tsv` (125k entries, 8.3 MB; built by `scripts/build-lexicon.py`). `Lexicon` loads it once in the background at launch and is consulted only by the app (`NotePageModel` passes `StarterVocabulary.full`); tests that inject a reader keep the 8-entry list. Single toneless syllables (`he`, `me`), proper names and variant entries are never looked up from Pinyin alone.
- **Row-context reading** (`NoteReading.lines`): each multi-cell row is read as one line first; if its words line up with the cells, each cell takes its word. Reason: `xué` read alone as a tiny crop came back `xJe`; inside its row it reads far better.
- **Larger Paddle model** (`PinyinRecognition.onnx`, the first result of "Run Pinyin OCR by line") is a separate engine (`PaddleServer`) beside the mobile model. DEBUG builds only, like the mobile model.
- **Dictionary repair** (`StarterVocabulary.repairedProposal`): when Hanzi is written and the Pinyin cannot be read as spelled, dictionary words that begin with that Hanzi are ranked by closeness to every reader guess (lower-ranked ones included, as scores only, never as text). Flagged uncertain. Replace is allowed only when the Hanzi is solid; Restore brings the ink back.
- **Tone slip**: when every reader agrees on the Pinyin and only its tone marks differ from the dictionary's, Replace writes the dictionary's Pinyin.
- **English leak fixed**: English from a whole-note reading is ignored when the note has no English ink (`学die xi`).
- **UI**: alternatives show Pinyin and meaning; the status message wraps and says each reason once.
- **Verified on the iPad** (`学 xué xí`, `diàn nǎo`, `好`, `好 hǎo xiang`): suggestion appears, Replace and Restore work. **Not verified**: general handwriting accuracy, force-quit reopen, undo and export after these changes, release builds (the Paddle models are DEBUG-only).
- **Debug**: `DebugTrace` writes `Documents/trace.log` in DEBUG builds; pull it with `devicectl device copy from --domain-type appDataContainer`.
- **Signing**: free-account profiles last 7 days. Reinstall needs Xcode signed in and the profile trusted on the iPad.
- **Pinyin with no Hanzi**: `Lexicon.repairCandidates(forPinyinReadings:)` finds the dictionary word closest to the readers' guesses (at least 4 letters; within 1 letter, 2 for long words; shares the first or last letter; its tones agree with the tone marks written; names and variants skipped). Only runs on Pinyin-shaped readings with at least one tone mark. Offered as a note only: Replace needs a confirmed Hanzi. Verified on the iPad for garbled `xuéxí` and `diàn nǎo`.
- **Word frequency**: the fourth column of the bundled table (jieba word list, MIT; `NOTICE.md`; 90,877 of 125,322 entries have one) ranks words that are spelled the same, so `shì` offers 是 before 事 and `dà` offers 大 before 汏. Rebuild the table with `scripts/build-lexicon.py cedict_ts.u8 jieba_dict.txt`. Frequency comes from a general corpus, so it is a tiebreaker, not a meaning ranking; it is not tuned to the student's course.
- **One plain syllable** (`shì` read as `Shi` by both Paddle models and `She` by PencilKit): plain syllables that are not an English word, read alike by two or more independent engines, are Pinyin, and a single engine's English look-alike one letter away is outvoted. A real English word read alike by everyone stays English. When the agreed reading lost its tone mark but the engines' lower-ranked guesses agree on one toned spelling (`Shì`), that tone is used, marked tentative.
