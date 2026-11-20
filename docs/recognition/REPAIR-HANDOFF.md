# Recognition repair: handoff

Supersedes the "Next repair assignment" in `HANDOFF.md`. Design: `repair-flow.md`.

## State

| Item | Value |
|---|---|
| Branch | `task/recognition-repair` (from `d28b745` = PR #25 stage 3 + PR #27 docs) |
| Draft PR | see the PR for this branch (base: PR #25's branch; nothing here is merged) |
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
