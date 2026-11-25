# Recognition repair: the one corrected flow

Branch `task/recognition-repair`. This document is written before the code and updated to match it. It states what exists, what does not, and what is verified.

```
original ink
  → spatial note groups        (NoteLayout → NoteReading.mergedCells → NoteGrouping, incl. same-row Pinyin joining)
  → retained OCR evidence      (NoteEvidence: every reading, tagged engine + scope cell/field/entry; raw, never shown as text)
  → shared field resolution    (FieldResolver: Hanzi / Pinyin / English validated separately → ResolvedNote)
  → suggestions                (Suggest reads ResolvedNote.cleanText; only vocabulary entries propose completions)
  → accepted fields            (AcceptedAnnotation: what the student approved or edited, authoritative)
  → flashcards                 (cards read the same ResolvedNote, and accepted fields override it)
```

## Rules

1. **One reader.** Suggest and Cards call the same `PencilInkLineReader` pipeline in the same mode. They get the same `RecognizedLine`s, each carrying one `ResolvedNote`. There is no second reduction of OCR evidence anywhere downstream.
2. **Evidence is retained, not reduced early.** For every note the reader collects readings of (a) each layout cell, (b) each Latin field's joined strokes (`hǎo` + `xiang` as one region) and (c) the whole entry (`好 hǎo xiang` as one line). Each reading from PencilKit, Vision and, in Debug builds, the local Paddle mobile model. Whole-line context is never dropped because a grouping decision was made first.
3. **Raw OCR is diagnostic.** `RecognizedLine.diagnostics` lists readings that were not accepted, for the Debug view and the "check it" message. They are never "Other readings", never dictionary alternatives, never replacement ink. The old "readings fallback" that turned every OCR string into a candidate is removed.
4. **Fields are validated apart.**
   - Hanzi: Han ideographs only.
   - Pinyin: must split into real Mandarin syllables with at most one tone mark per syllable, on a vowel. `hňo` is not Pinyin. A malformed reading of Pinyin stays *Pinyin-unresolved*; it never becomes the English field.
   - English: must not be a romanization (checked against the Hanzi's romanization and Pinyin syllable validity) and not carry tone diacritics.
5. **Status per field**: `confirmed` (valid and corroborated by another reading or the vocabulary), `tentative` (valid, one source or disputed tones), `unresolved` (no valid reading; the field is empty, not guessed). Replace is always offered (product decision, 2026-11-21): the chip previews the exact text it writes, an unresolved or tentative field shows its caveat on the chip, and Restore brings the original strokes back. An unresolved field is never filled by a guess.
6. **Nothing is invented.** Unknown words stay unresolved: no English is produced. Only entries of the offline starter vocabulary propose completions.
7. **Accepted fields win.** Cards use the accepted Hanzi/Pinyin/English of a note; a note without approved English makes no card.

## What semantic verification exists

Honest inventory (`grep` of the whole app and `Config/` finds no `URLSession`, API key, provider setting or network call):

| Layer | What it is | Is it AI? |
|---|---|---|
| `StarterVocabulary` | 8 hand-written entries (负责 承担 预习 复习 虽然 但是 好像 农夫市集) | No |
| `PinyinValidator` (new) | Mandarin syllable table (also used by `ReadingCrossCheck`) + tone-mark placement rules | No |
| `PinyinContextHint` | Foundation Han→Latin transform, used to compare *letters* of a Hanzi with written Latin | No |
| PencilKit / Vision / Paddle mobile | Handwriting/text recognition; their output is *evidence*, not verification | Recognizers only |
| Cloud or on-device LLM | **None configured.** | — |

There is no general dictionary and no semantic AI check. Validity checks above say a string is *well-formed Pinyin*, not that it is the right word.

### Options for a real semantic layer (not added; each needs a decision)

- **CC-CEDICT** (CC BY-SA 4.0, ~120k entries, free, bundled offline). The natural next step: real dictionary alternatives and glosses with no network and no cost. Needs a licence/attribution decision and an import step.
- **Apple Foundation Models (on-device, iOS 26+)**: free, private, no upload. Availability on iPad Air (M4) and quality for Mandarin lexicography must be measured before relying on it.
- **Cloud LLM / dictionary API**: would send note content off the device. Not added. Requires explicit consent (see CLAUDE.md) and a cost decision.

## Known limits

- Real handwriting accuracy is only established by device runs. Simulator PencilKit has no Chinese; injected-reader tests prove the logic, not recognition.
- PaddleOCR mobile exists only in Debug builds (`#if DEBUG`), where the local models are present.

## Replace in place (issue #29)

Replacing the unedited first suggestion writes only what the note is missing, around the student's own strokes (`InlineReplacement`):

- **Hanzi** that is missing goes after the Hanzi that is there, at its measured size; it may be made narrower to fit. With only Pinyin written, the word goes in front of it.
- **Tone marks** are drawn over the student's own letters. Decision: overlay, not redraw. Pinyin read a letter or two wrong, but with the same number of letters, also keeps the student's writing (the readers are far more often wrong than the student). Pinyin with wrong tones or a different number of letters is rewritten, and only the Pinyin.
- **English** follows the Pinyin at its size, or goes under the note when the line is full.
- Nothing is written over other ink or past the page. When the fields cannot be told apart or there is no room for the Hanzi, the whole line is replaced as before. Edited text and alternatives also replace the whole line.
- `InkReplacement.keptStrokeIDs` records the student's strokes the note stands on. They are confirmed with it, so Suggest and Cards do not read them again, until any of them changes. Restore removes what was added and brings back any rewritten Pinyin; Delete does the same, so the student's ink is never deleted with it.
