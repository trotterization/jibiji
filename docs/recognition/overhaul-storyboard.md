> **Status banner (read first).** This is the *planned* design. It is NOT what is installed or shipped. The stage-3 build tested on the iPad (PR #25, commit `308d4d0`) is faulty: see `ipad-deployment-audit.md` and `HANDOFF.md`. Statements below that describe grouping, shared validation, dictionary alternatives, semantic checks or per-field state describe intended behaviour; most of it is absent, and nothing here has been verified on real handwriting.

# JIBIJI recognition / suggestions / flashcards overhaul — plan and storyboard

Status: **design only. No source edited, nothing built, tested, installed or published.**
Audited commit: `69c1793` (installed baseline; detached HEAD in `work/jibiji-install-main`). Public `origin/main` was fetched and is **identical** (`69c1793`), so main has not moved.
Scope: recognition → grouping → suggestions → accepted corrections → flashcard generation/export accuracy **only**. Notebook, canvas, home, cover, theme, ink tools, Quizlet file format and everything else stay as they are.
Privacy/cost constraints honoured: no new paid service, no cloud upload, synthetic examples only (no user ink, no classroom content).

> Ground rules for reading this: every statement tagged **[CODE]** was read in the audited source (file:line). **[HYP]** is a plausible cause that the code allows but that on-device evidence has not confirmed. The user's spoken romanizations ("Fuza", "nongfu") are treated as *uncertain labels*; this document does not decide what term they stand for and no diagnosis below depends on a guessed translation. Exact screenshots/text are still to come and Section 9 lists what each one must settle.

---

## 0. Worktrees and code versions (preserved, untouched)

| Worktree | Branch / HEAD | Relation to main `69c1793` |
|---|---|---|
| `jibiji-install-main` (this) | detached `69c1793` | = origin/main = installed baseline |
| `jibiji-current-main` | `task/note-analysis` `2a8d6e3` | **1 commit ahead**: Debug-only Note Analysis (`NoteLayout`, `NoteGrouping`, `NoteAnalysis*`, +1261 lines, touches `NotePageView.swift`). Overlaps Section 3/4 grouping work — see Stage 4. Not merged, not read for conclusions here beyond its file list. |
| `jibiji-issue11`, `jibiji-issue12`, `jibiji-canvas` | `task/issue-11-…`, `issue-12-…`, `canvas-zoom-pan` | 0 commits ahead of main (already merged / empty) |
| `jibiji-preview`, `jibiji-pr9` | preview branch / detached | not inspected; left as is |

The GitHub CLI is available in this workspace at `../tools/bin/gh` (relative to the repo checkout; it is simply not on `PATH`, which is not a project constraint). It was not used for this planning pass, so no issue/PR text has been read yet; read the relevant issue/PR via that binary before implementation begins. The user's existing authorization covers this recognition work; stages below are a suggested order, not separate approval gates.

---

## 1. Storyboard (one user, one page, several notes)

Synthetic page: three notes the user wrote at different times — **A** Hanzi + Pinyin + English side by side; **B** the same three fields *stacked* (Hanzi on top, Pinyin below, English below that); **C** a partial entry (`好 hǎo xiang`, a Hanzi prefix plus untoned Pinyin).

| # | Scene | What the user sees / does | What the system does (target behaviour) |
|---|---|---|---|
| 1 | **Write** | Writes A, B, C with Pencil. Original strokes are never altered. | Each pen stroke bumps the page ink revision; strokes are clustered into *note regions*. When recognition runs is unchanged from today (existing triggers are preserved); this storyboard only shows the explicit Suggest tap. |
| 2 | **Recognize & group** | Taps **Suggest** once (existing trigger behaviour is preserved; nothing here mandates that recognition runs only on demand). | Every note region is read independently. Hanzi / Pinyin / English *fields* are assigned by script and position, so side-by-side (A) and stacked (B) layouts both yield one note with three fields. Raw readings from each engine are kept with provenance. |
| 3 | **Inspect tentative correction** | A calm chip appears beside **each** note that has something to offer (A, B, C get their own chips), each showing only the *affected fields*: e.g. for C, `像` + English; for a note with unmarked Pinyin, the tone-marked reading; for an uncertain note, "can't tell — here is why". | Chip shows *what changes, which field, and why* (provenance: "from your ink" / "from the starter list"). Unresolved fields are shown as unresolved, never filled. |
| 4 | **Accept / edit / reject** | Accept C → only the missing fields are added (the existing "Replace with clean handwriting" look is tolerated for now). Edit B's English then accept. Reject A. | Accept writes the accepted fields to the note record (authoritative, user-edit flagged). Edit marks the English field `userEdited`. Reject records "rejected at note revision N": that proposal is suppressed for the same source revision and returns only if the note's source changes. Original strokes are kept and recoverable. |
| 5 | **Repeat Suggest** | Taps **Suggest** again. | Accepted notes are **not re-read**, not re-suggested, and their generated ink is **never** treated as new handwriting. Rejected note A stays suppressed for its unchanged source revision (no re-nag); untouched notes never accepted or rejected, and new note D, are evaluated as before. Result: the same pending set minus what was accepted or rejected. |
| 6 | **Create cards** | Opens Cards → Generate. | Cards come from each note's *resolved/approved fields*: front = Hanzi, back = Pinyin — English. A note with unresolved or unconfirmed fields yields a **draft flagged "needs review"**, can't be approved silently, and never puts romanization in the English slot. |
| 7 | **Review & export** | Edits a card, approves, exports Quizlet TSV. | Only approved, *current* cards export (existing rule, unchanged). The card's provenance links to the note and its revision. |
| 8 | **Edit source, undo, reopen** | Erases/rewrites B's Hanzi; undoes; force-quits; reopens. | Only note B's revision bumps; its pending suggestions, accepted correction and cards are invalidated *for B alone* (cards re-drafted + flagged). Undo restores B's previous revision state. A and C are untouched. Reopening only reloads saved state: it does **not** invalidate an accepted note. Only an actual edit to a note's relevant source ink does. After reopen, all records load identically; Suggest is idempotent. |

---

## 2. Current call flow and evidence-backed failure mechanisms

### 2.1 Actual call flow at `69c1793` [CODE]

**Suggest**
1. `NotePageView.swift:242` → `page.suggestions.request(for: page.drawing)` — the **whole** drawing, including previously generated replacement strokes.
2. `PageSuggestionModel.request` `:327-343` → `reader.lines(in:)` → `PencilInkLineReader` (`:63-106`, mode `.suggestions`).
   - 2a. If the `JibijiUsePaddlePipeline` default is set (`:65-79`, checked **before** any mode test, so shared by Suggest and Cards): `PaddleTextPipeline.lines` + Vision readings + `RecognitionCrossCheck.resolve`. This branch **skips `InkLineGeometry.lineGroups`**.
   - If iPadOS 27 + PencilKit zh-Hans (`:83-86`): `InkLineGeometry.lineGroups` (`InkLineGeometry.swift:24-62`) → PencilKit text per group → `HanziPrefixFallback` (Debug-only Paddle, `:98`) → Vision `lineReadings` as extra "readings" (`:99`).
   - Otherwise (Simulator / older OS): `VisionInkReader.lines` (`VisionInkReader.swift:36-52`) clusters strokes touching within 12 pt (`:56-72`), OCRs each crop (`:74-129`), Debug adds PaddleOCR (`:112-127`).
3. `finish` `:345-399` → `RecognitionCrossCheck.resolve` (`:7-9`: `joinedRegions` + `ReadingCrossCheck`), then per line: `vocabulary.proposal(forRecognizedText:)` (`StarterVocabulary.swift:155-213`), else a "readings" fallback (`:361-366`), else abstain (`:367-374`).
4. Dedupe against accepted notes `:375-378`; `PendingSuggestion` built `:387-390`.
5. Accept: `PageSuggestionModel.accept` `:418-440` (note) or `NotePageModel.replaceSuggestion` `:116-148` → `CleanHandwriting.drawing` (`CleanHandwriting.swift:36-78`) → `acceptReplacement` `:444-463` → `NotePageModel.drawingDidChange` (`:104-112`) → `PageSuggestionModel.sourceDidChange` (`:290-296`) clears all pending, then `keepUnchangedPending` `:508-515` restores others.

**Cards**
1. `FlashcardsView.swift:134` → `PageFlashcards.refresh(from:annotations:)` `:150-180` → reader created as `PencilInkLineReader(mode: .primaryOnly)` (`:70`). Cards omit only the Debug `HanziPrefixFallback` pass (`PageSuggestionModel.swift:98`); the Paddle-pipeline branch (`:65-79`) is shared by both modes.
2. `merge` `:184-287`: lines overlapping a **replacement** note are dropped and the note's own text substituted (`:186-194`); other accepted notes only claim a line when `lines[$0].rawText == note.recognizedText` **and** anchors intersect (`:201`); every unclaimed line goes through `FlashcardExtractor.extract(from: line.text)` (`:256-284`).
3. `FlashcardExtractor.vocab` `:166-216` splits Hanzi / Pinyin / "gloss" purely by token order and Pinyin match.

### 2.2 Failure mechanisms

Legend: **Confirmed mechanism** = the code unquestionably does this (behaviour on the user's exact ink still to be matched to a screenshot). **Hypothesis** = needs evidence.

| ID | User-observed failure | Mechanism | Status |
|---|---|---|---|
| **M1** | Accepted replacement (font-like ink) is corrected again by the next Suggest | `request(for:)` hands the *entire* drawing, generated replacement strokes included, to the reader (`NotePageView.swift:242`, `PageSuggestionModel.swift:327-343`). Nothing removes `InkReplacement.replacementStrokeIDs` (`CleanHandwriting.swift:312-316`) from the input. The only dedupe, `alreadyAccepted` (`:375-378`), compares `note.recognizedText` (the **original handwriting's** reading) with the re-OCR of the **new font ink** (`line.rawText`), which will differ, so — **if the two readings differ, which is plausible but not yet shown** — the note is treated as fresh handwriting. Confirmed: nothing excludes generated ink from the reader input. Hypothesis: the re-OCR differs and also yields a proposal (via `proposal` or the readings fallback). By contrast the card path *does* exclude replacement ink (`PageFlashcards.swift:186-194`) — an asymmetry. | **Confirmed mechanism** |
| **M2** | The re-correction is gibberish with digits/mixed letters | The readings fallback (`:361-366`) builds candidates with `SuggestionCandidate(hanzi: $0, …)` from **entire OCR reading strings** whenever any reading contains a Han character and the readings disagree on Hanzi (or the line is one character). No check that a "hanzi" field contains only Han characters, so Latin/digit noise ends up as the proposed text. Skeleton strokes of a font (`GlyphSkeleton.centerlines`, thin one-pixel centrelines) are an out-of-distribution input for handwriting OCR, which makes disagreeing/noisy readings likely. | Mechanism confirmed; **that this is the trigger on the user's page is a hypothesis** until the screenshot shows the offered candidates. |
| **M3** | Flashcard English definition is the untoned/wrong OCR pronunciation | Three independent paths put romanization in the gloss: (a) `FlashcardExtractor.vocab` `:203,212` — gloss = *everything after the consumed Pinyin words*; if the OCR Pinyin does not fold-equal the expected syllables (`:179` / `:196`), `consumed == 0` and the **whole OCR Pinyin becomes the English** (it is only flagged `needsReview`, `:210,214`, still emitted). (b) `AcceptedAnnotation.parse` `:210-231`: a "·" part is Pinyin only if its folded letters equal the candidate's; otherwise it falls to `glossParts` (`:226-227`) so a misspelled/misread Pinyin written into the note becomes the stored `gloss`. (c) *only when the final text contains no "·"* (e.g. the user edited the dots away; the normal `" · "`-joined `replacementText`, `:134`, takes the tone-insensitive `parse` path at `:486-490`) `replacementParts` `:484-506`: Pinyin is recognised only by case-insensitive *prefix match against the toned* candidate Pinyin (`:497`); untoned text fails the prefix test so the remainder becomes `gloss` (`:503`). Also: an accepted *note* only claims its line when the card-time re-read has identical `rawText` (`PageFlashcards.swift:201`) — but Suggest and Cards use different readers (see 2.1), so a mismatch drops the note and the **raw OCR line** goes straight to the extractor (`:256-257`). | Mechanisms confirmed; which one fired on the "nongfu" example is a hypothesis. The lexicon does contain one entry with syllables starting `nóngfū` (`StarterVocabulary.swift:76`) — **not** used here to guess the user's term. |
| **M4** | 好像 does not fill the missing fields | (a) `proposal(forRecognizedText:)` needs the entry's Pinyin (tones optional, `:160`) before a Hanzi *prefix* counts (`:171-177`). **Correctly read, untoned Pinyin already works, so E4 may pass on clean input**; failure needs a misread syllable (the `nearRange` fallback at `:164` requires the Hanzi to be fully written) or a contradicting Han run. A prefix with no usable Pinyin has no route to a suggestion, and any contradicting Han run **aborts the whole line** with `return nil` (`:175`), as does any leftover Latin that is not a run of the entry's gloss (`:196`). (b) Replace is blocked when the Pinyin state is wrong-tones/possible-spelling (`:155-157`), leaving only "add as note". (c) For the primary candidate the replacement keeps the *written* Pinyin (`:132`), so tones are not filled into the ink. (d) The Hanzi 好 is mis-read by PencilKit in the Simulator (CLAUDE.md evidence); on device this depends on PencilKit zh-Hans support (`:83-86`). | (a)(b)(c) confirmed by reading; (d) device-dependent hypothesis. |
| **M5** | After one suggestion, other notes are missed; mostly "Fuza" | Candidate contributors: (1) *(PencilKit path only; the Paddle-pipeline branch skips `lineGroups`)* `lineGroups` falls back to **one group for the entire page** whenever <4 body strokes, any group <2 strokes, or <2 groups (`InkLineGeometry.swift:30-34,50`) — a page of short notes gets concatenated into one "line"; `proposal` then sees multiple Han runs and abstains (`StarterVocabulary.swift:169,175`). (2) `proposal` returns only **one** entry per line and iterates in fixed vocabulary order (`:159`), so the first-listed entry that matches wins (负责 is entry #1, `:69`) and a later note on the same merged line cannot be offered. (3) M1 noise: replacement-ink readings occupy the result list; the "no match" explanation is shown only when *nothing* was offered (`:393-397`), so one spurious chip hides why other notes were skipped. (4) `joinedRegions` (`RecognitionCrossCheck.swift:36-70`) joins a Hanzi box only with Latin boxes to its **right** on the same row (`:47-49`); a stacked layout is never joined. | (1)(2)(4) provable from code; **which one explains "mostly Fuza" is a hypothesis** until we see page layout + chosen reader. |
| **M6** | Whole line replaced, not only affected fields | `replaceSuggestion` takes *all* strokes in the line's bounds (`:124,129-132`), draws the entire `cleanText` into the union bounds scaled to fit (`CleanHandwriting.swift:66`), and stores one text blob. There is no per-field model, so "limit corrections to affected fields" cannot currently be expressed. | Confirmed (user tolerates the font look; the problem is field scope). |
| **M7** | Docs/lexicon honesty | The "starter vocabulary" has **8** entries (`StarterVocabulary.swift:68-77`; `docs/recognition/accuracy.md` says seven). It is a demo list, not understanding; any claim of sense/tone verification beyond these 8 words would be false. | Confirmed |
| **M8** | Different engines at suggestion vs card time | Reader modes differ (`PageSuggestionModel.swift:61,98` vs `PageFlashcards.swift:70`): on the PencilKit path the Debug `HanziPrefixFallback` runs for Suggest only, so identical ink can yield suggestion text ≠ card text. (The Vision whole-ink cache, `VisionInkReader.swift:38-39`, is shared and does **not** cause a mismatch.) Consequence: an accepted note's fields reach a card only if the card-time re-read has the same `rawText` (`PageFlashcards.swift:201`). | Confirmed |

Not yet explained by code (needs evidence): exactly which reader/build produced each screenshot (Debug with Paddle models vs Release; `PKStrokeRecognizer.supportedLanguages` on the device; `JibijiUsePaddlePipeline` default, `PageSuggestionModel.swift:65`).

---

## 3. Proposed shared structured note record

One record per **note** (a user-meaningful unit: one vocabulary entry or sentence), shared by Suggest and Cards. Stored additively as `<pageID>.notes.json` beside the existing `.annotations.json` / `.flashcards.json` (those remain readable; see §8 migration).

```
NoteRecord
  id: UUID
  schemaVersion: 1
  revision: Int                     // per-note, bumps only when THIS note's source changes
  source:
    strokeIDs: [String]             // InkSelection.identity of ORIGINAL strokes (content hash)
    bounds: CGRect                  // union of those strokes, page coordinates
    inkDigest: String               // digest of only these strokes (per-note, not whole-page)
    origin: handwriting | generated(of: UUID)   // generated ink is never a source
    layout: sideBySide | stacked | single | unknown   // as grouped, with confidence
  fields: { hanzi, pinyin, english }            // each a Field, below
  corrections: [Correction]         // accepted/edited/rejected history (newest last)
  uncertainty: [Flag]               // coded reasons, per field
  cards: [CardRef]                  // derived card ids + the (note revision, field versions) used
  state: new | evaluated | tentative(pending) | accepted | rejected(atRevision) | stale

Field
  candidates: [Reading]             // raw, never discarded:
                                    //   text, engine(pencilKit|vision|paddle|lexicon|user),
                                    //   passID, rank/confidence if provided, bounds, rawBeforeNormalization
  resolved: text?                   // the single value the app treats as current
  status: confirmed | tentative | unresolved | absent
  provenance: writtenInk | lexicon | userTyped | crossChecked(from:…)
  userEdited: Bool

Correction
  id, kind: complete | tonize | respell | replaceInk | note, fields: Set<FieldName>,
  before: [FieldName: String?], after: [FieldName: String],
  decision: accepted | edited | rejected, atRevision: Int, createdAt,
  inkReplacement?: { originalInk(Data), originalIndices, generatedStrokeIDs }   // = today's InkReplacement

Flag
  code: pinyinNotValidSyllables | toneConflict | possibleSpelling | enginesDisagree |
        heteronym | senseUnknown | hanziUncertain | gibberishRejected | layoutAmbiguous | lexiconMiss
  field, detail (plain language), blocksApproval: Bool
```

Invariants
- **I1** Original strokes are the only OCR input. Generated ink (`origin: generated`) is excluded from reading by construction.
- **I2** `resolved` for an accepted/edited field is authoritative; OCR may add `candidates` but cannot change it.
- **I3** Any source change bumps only that note's `revision`; fields and cards derived from the old revision are invalidated for that note only.
- **I4** A field's `status` can be `confirmed` only through user acceptance/edit or an exact, unambiguous lexicon/dictionary match of an already-confirmed neighbour field.
- **I5** Cards are pure functions of `fields.resolved` + `status`; they never read OCR text.

---

## 4. Logical flow and validation boundaries

```
strokes ─B0→ note regions ─B1→ raw readings ─B2→ field assignment ─B3→ field validation
        ─B4→ completion proposals ─B5→ sense/tone consistency ─B6→ uncertainty/abstain ─B7→ user decision → resolved fields → cards
```

- **B0 Segmentation / grouping.** Cluster original strokes into notes using proximity in both axes, *not* only a left-to-right row join. Layout is inferred, not assumed: fields may be side-by-side or stacked (same x-range, increasing y). Ambiguous layout → `layoutAmbiguous`, never a silent guess. (Today: `lineGroups` horizontal bands, `joinedRegions` right-neighbours only.) Reuse candidate: the unmerged `NoteLayout`/`NoteGrouping` work on `task/note-analysis` — a coordination point with its author (Stage 4).
- **B1 Raw readings.** Run each engine on the note's strokes; record every candidate with provenance. No cleaning here. Cache per `(note.inkDigest, engine, version)`, never per whole page.
- **B2 Field assignment** by script + context, not token order: Han characters → Hanzi; a Latin token sequence that parses as Mandarin syllables (existing `ReadingCrossCheck.isPinyin`/`syllables` table) *and* is in the pinyin slot (after/below the Hanzi, or standalone) → Pinyin; remaining Latin → English. A standalone Pinyin note is a first-class case (the CLAUDE.md "standalone marked Pinyin").
- **B3 Per-field validation** (all local, deterministic):
  - *Hanzi field*: Han characters only. Latin letters or digits inside it ⇒ OCR noise ⇒ reject candidate (`gibberishRejected`), keep as raw reading only. (Would have blocked M2.)
  - *Pinyin field*: letters of valid syllables, tone marks, `ü/v`, apostrophe/hyphen/space. **Digits here are legitimate only as tone numbers** (`hao3 xiang4`): convert deterministically to tone marks and mark provenance; any other digit ⇒ OCR noise.
  - *English field*: letters, spaces and ordinary gloss punctuation **and digits/symbols** (`(1)`, `A/B`, `;`, `…`, `to ~ sth`, years) are legal. Gibberish is judged by shape (mixed scripts within a token, impossible character mix), not by banning digits.
  - *Grammar/pattern notes* (`虽然…但是…`, "Example:"): `…`, `~`, `A/B`, digits are legal; validated by their own extractor rules, not the vocabulary-note rules.
- **B4 Actual spelling vs OCR error.** Spelling slip = Pinyin that parses as valid syllables but differs from the dictionary reading of the (confirmed) Hanzi. OCR error = invalid syllables, an engine disagreement, or a small edit/confusable-glyph distance. When indistinguishable the verdict is `possibleSpelling`/`enginesDisagree`: shown as uncertain, **never auto-applied to the user's writing** (matches today's intent at `PageSuggestionModel.swift:153-157`, kept and made field-scoped).
- **B5 Missing-field completion.** Allowed only from an authority (lexicon/dictionary) keyed by an already-confirmed or exactly-matched field: Hanzi → Pinyin+English; Pinyin → Hanzi candidates (ambiguous ⇒ list, not pick); Hanzi prefix + Pinyin → the rest (the 好 → 像 case). Completion proposes only the **missing** fields; written fields are untouched. Source text must never be promoted into the English field because of position.
- **B6 Sense/tone consistency.** The proposed English must belong to the same sense as the proposed Pinyin. For heteronyms or multi-sense entries the system **lists senses and asks**, or abstains (`heteronym`/`senseUnknown`). Tone check compares letter-by-letter, never normalising a written wrong tone away (existing `RecognitionCrossCheck.tonesAgree` semantics kept).
- **B7 Abstention and honesty.** Every note ends in exactly one of: `confirmed`, `tentative` (with plain reason), `unresolved` ("can't tell"), or `no suggestion`. There is **no guarantee of perfect OCR**; the contract is "never present a guess as fact, never overwrite the user's ink, and surface the doubt".

### Where a dictionary or semantic AI is truly needed vs local checks

| Capability | Local deterministic is enough | Needs a dictionary | Needs semantic AI/LLM |
|---|---|---|---|
| Script/field split, tone-number → tone-mark, invalid-syllable detection, digit/symbol rules, stroke-set bookkeeping, idempotency | ✅ (syllable table + regex already in repo) | | |
| Hanzi → Pinyin for a *confirmed* word | partially: ICU `mandarinToLatin` gives one reading per word, **wrong for heteronyms** | ✅ for reliable multi-reading | |
| Hanzi → English gloss, completing 好→好像, choosing a sense | ❌ | ✅ real dictionary (not the 8-entry list) | ✅ only to *rank senses in context* |
| Telling "student's spelling slip" from "OCR misread" when both are plausible | ❌ (stays `uncertain`) | helps (valid-word check) | helps only as a weak tie-break |
| Is this English gloss a correct meaning for this word in this sentence? | ❌ | partial (match to dictionary glosses) | ✅ genuinely semantic |

The current `StarterVocabulary` (8 entries, `StarterVocabulary.swift:68-77`) is a proof-of-flow fixture. It must not be described as general understanding; outside it the correct behaviour is abstention (already coded at `PageSuggestionModel.swift:367-374` and kept).

**Options for genuine semantic verification (no cloud, no paid service; all need verification before commitment):**
1. *Bundled open dictionary* (e.g. CC-CEDICT, which is freely downloadable; its licence is CC BY-SA, so attribution and share-alike obligations must be checked against the app's distribution before bundling). Gives Hanzi↔Pinyin↔glosses with multiple senses and heteronyms. Dependency: legal review, a build step to compile it to a compact local index, size on the iPad. **Recommended first step** — it removes most of M3/M4 without any AI.
2. *Apple on-device language model* (Foundation Models framework) to rank senses or flag implausible glosses. Dependency: availability/entitlement on the target iPad Air (M4) and iPadOS version, a measured latency/quality test, and graceful fallback when unavailable. Must be used only to *rank/flag*, never to author glosses unchecked.
3. *Local open-weights model via Core ML/ONNX* (already have ONNX Runtime vendored for Paddle). Dependency: licence, size, latency, and an evaluation set; heavier than option 2.
4. *Cloud LLM*: **excluded** by the constraints (upload + cost); would require explicit consent (CLAUDE.md) and a separate decision.
5. *Human-in-the-loop only*: keep everything `tentative` and require user confirmation. Always available; this is the default fallback for every option above.

Recommendation: Stages 1–6 (below) need **no** semantic AI; option 1 is the first dependency; option 2 is an optional later spike with an explicit go/no-go measurement.

---

## 5. Idempotent repeated Suggest

Algorithm (per page, any number of times):
1. **Exclude generated ink**: remove every stroke whose id is in any `Correction.inkReplacement.generatedStrokeIDs` (or whose note `origin == generated`) *before* segmentation. Generated ink is rendering of a decision, not evidence.
2. **Segment** remaining strokes into note regions and **match them to existing records by stroke-ID set overlap** (not by OCR text, which is what `alreadyAccepted` does today at `:375-378`).
3. For each record: unchanged `inkDigest` + `accepted` ⇒ skip, no OCR, no chip. Unchanged + `rejected(atRevision == revision)` ⇒ skip. Unchanged `tentative` ⇒ reuse cached evaluation. Changed ⇒ `revision += 1`, re-evaluate. New region ⇒ new record.
4. A pending suggestion carries `(noteID, revision)`; `accept` ignores it if the revision moved (replaces today's whole-page `sourceDidChange` revision, `PageSuggestionModel.swift:290-296`, which wipes *every* pending chip on any stroke).
5. The "no match" explanation is per note, not suppressed by another note's chip.

Properties (each a test, §7): running Suggest twice with no edits yields the same pending set; accepting note X changes nothing for notes ≠ X; accepted fields are byte-identical after N Suggest runs; editing X's source invalidates only X.

---

## 6. Card generation consuming the same record

- Input: `NoteRecord.fields[*].resolved/status`, not OCR lines. Output: `front = hanzi`, `back = "pinyin — english"`; a missing field is **omitted or flagged**, never filled from another field.
- Rule: a card's `back` English slot may only be filled from `english.resolved` (or a lexicon gloss the user accepted). Romanization found in that slot by an explicit validator (B3 Pinyin test) ⇒ block creation as approved and flag `romanizationInGloss`.
- States: any field `tentative`/`unresolved` ⇒ card is `draft` + `needsReview` with `blocksApproval` reasons shown; `approve` is refused until the user confirms or edits those fields (today `approve` only checks non-empty text, `PageFlashcards.swift:353-361`).
- Source link: card keeps `(noteID, noteRevision, fieldVersions)`; a revision bump on that note re-drafts and flags it (the existing re-draft rules at `:225-247` are the model, now keyed by note not by OCR line text).
- Migration of existing cards: an already-approved card is carried over as `approved` with its fields `confirmed` (`userEdited` if `card.edited`); it is **not** re-flagged unless its note's revision later changes.
- Non-vocabulary extractor kinds (labels, arrows, grammar, idiom, equation — `FlashcardExtractor.swift:24-32`) are **kept as they are**; only the vocabulary path (`vocab`, `:166-216`) is rerouted through the record. Export format and the "approved current cards only" rule are untouched.

---

## 7. Shared evaluation / verification cases

One fixture set drives unit tests (injected `InkLineReader`/readings — no PencilKit recognition needed), and a short physical-iPad checklist. All text below is synthetic; `⟨T⟩` marks the user's two uncertain terms, to be bound to the real examples when screenshots arrive (screenshots are evidence for exact reproductions, not a prerequisite for the confirmed fixes).

| ID | Case | Input (synthetic / injected) | Pass condition |
|---|---|---|---|
| E1 | Replacement not re-corrected (F1) | Accept a replacement, run Suggest again | No pending item overlaps the generated strokes; accepted fields unchanged |
| E2 | Gibberish with digits rejected (F2) | Injected readings `["大","x7大 a3","牛"]` or `"fu2ze7 H"` for a region | Not offered as Hanzi candidate; `gibberishRejected` flag; no chip or an "unresolved" chip |
| E3 | Romanization never becomes English (F3) | `⟨T⟩`-style line: Hanzi + untoned/misspelled Pinyin, no English | Card: English slot empty/flagged, `needsReview`, `blocksApproval`; Pinyin kept in its own field; export excludes it until approved |
| E4 | 好像 completion (F4) | `好 hǎo xiang` | Proposes `像` + "to seem like; to look like"; tones as missing-tones; user's written fields untouched; accepted English appears on the card |
| E5 | Other notes not suppressed (F5) | 3 notes, accept one, Suggest again, ×2 | Remaining notes keep/produce their own chips; accepted note silent; no chip count change on a 3rd run |
| E6 | Side-by-side layout | Hanzi, Pinyin, English in a row | One note, three fields |
| E7 | Stacked layout | Same fields, one under another | Same record as E6 |
| E8 | Multi-note page, short notes | Several 1–2-stroke-group notes (the `lineGroups` fallback case, `InkLineGeometry.swift:30-50`) | Not merged into one note |
| E9 | Correct untoned Pinyin | `fuze` beside the Hanzi | `missingTones`; tone-marked reading offered as tentative, ink untouched |
| E10 | Wrong tone | Right letters, conflicting mark | `toneConflict`; shown as uncertain; no automatic ink replacement; user can still accept/edit |
| E11 | Ambiguous pronunciation / heteronym | A Hanzi with two readings (fixture lexicon entry) | Lists both senses or abstains; never picks silently |
| E12 | Malformed OCR | Empty, huge, mixed-script, newline-containing, non-finite bounds | No crash; abstain; ink unchanged |
| E13 | Repeated Suggest idempotent | Suggest ×3, no edits | Identical pending sets (minus accepted); no re-OCR of accepted notes |
| E14 | Edit/undo/reopen | Edit note X's English, accept; erase/undo source; force-quit; reopen | Only X invalidated; fields/cards restored identically after undo/reopen |
| E15 | Accepted English wins | Edit English then accept, create card | Card back uses the edited English exactly; Quizlet export text for approved cards is byte-identical to today's format |
| E16 | Legitimate digits/symbols | English `(1) to seem; ~ like`; pattern `虽然…但是…`; Pinyin `hao3` | Accepted as valid; `hao3`→`hǎo` converted with provenance |
| E17 | Unknown term | Hanzi not in the lexicon | Abstain with the honest "not in the starter vocabulary" message, no invented gloss |
| E18 | Migration | Old `.annotations.json` + `.flashcards.json` fixtures | Records built losslessly; no data lost; re-export identical for approved current cards |
| E19 | Source-change invalidation per note | Change X, leave Y | Y's chip/card untouched |
| E20 | Original ink preserved | After all above | Original strokes still recoverable (`restoreOriginal` path) |

Physical-iPad checklist (separate from the Simulator result, per CLAUDE.md): E1, E4, E5, E7, E14, E15 on the real device, recording build config, OS, `PKStrokeRecognizer.supportedLanguages`, and which reader was used.

---

## 8. Small ordered implementation stages (suggested order, none started; no issue-per-stage gate)

All new behaviour sits behind one local flag (`JibijiRecognitionV2`, default **off**) until Stage 7; each stage is independently revertible.

| Stage | Change | Why first / reversible checkpoint |
|---|---|---|
| **0** | Capture evidence: screenshots + synthetic fixtures; add failing/expected-failure characterization tests for E1–E5 against current code. Tests only. | Locks in F1–F5 before touching anything. Checkpoint = tag at `69c1793`. |
| **1** | Hotfix pair: exclude `replacementStrokeIDs` ink from the Suggest reader input; refuse candidates whose "hanzi" is not Han-only (B3 Hanzi rule). Smallest change, fixes M1/M2. | Highest user pain, ~tiny diff; revert = one commit. |
| **2** | Pure types + validators (`NoteRecord`, `Field`, field classifiers, tone-number conversion, B3 rules) — no wiring. | No behaviour change; unit-tested in isolation. |
| **3** | `NoteRecord` store, **shadow only**: written next to existing files, built lazily from annotations/cards, nothing reads it. | Proves migration with real pages; deleting the file restores today's behaviour. |
| **4** | Segmentation/grouping (B0) incl. stacked layout and per-note ids; reconcile with `task/note-analysis` (reuse its `NoteLayout`/`NoteGrouping` if its owner agrees). | Touches overlapping files; coordinate with the `task/note-analysis` author. |
| **5** | Idempotent, per-note-revision Suggest + field-scoped accept (§5, M5/M6). | Core behaviour change behind the flag. |
| **6** | Card generation from records (§6, M3/M8); same reader/records for Suggest and Cards. | Removes romanization-in-gloss class of bugs. |
| **7** | Flip flag default on after Simulator + physical-iPad E-checklist pass; keep flag for one release. | Reversible by flag; old code path retained one cycle. |
| **8** | (Optional, separate go/no-go) bundled dictionary (§4 option 1) and, later, on-device model spike (option 2). | Independent of 1–7. |

**Migration of existing data** (Stage 3/7): per page, read `.annotations.json` (v1) and `.flashcards.json` (v1) as today; build `NoteRecord`s: each accepted annotation → a record with `accepted` fields from `hanzi/pinyin/gloss` (nil gloss ⇒ English `absent`), `corrections[0]` = the accepted note (keeping `InkReplacement` verbatim so Restore still works); each card with `correction.annotationID` links to that record; cards without a correction become record-less cards left exactly as they are. Never rewrite the old files in place; keep them as the rollback source until Stage 7 ships. Unreadable files stay untouched (today's `canSave = false` behaviour, `PageSuggestionModel.swift:272-280`, `PageFlashcards.swift:408-438`).

---

## 9. Evidence that will sharpen exact reproductions (promised "exact screenshot/text")

1. Screenshot of the *accepted* replacement and of the *second* Suggest chip's candidate list — settles M2's trigger (readings fallback vs another path).
2. Build config on the iPad (Debug with Paddle models, or Release), OS version, `PKStrokeRecognizer.supportedLanguages` — settles which reader ran (`:83-86`), and whether `HanziPrefixFallback` was active.
3. For "nongfu": whether the note was accepted as **Replace** (ink) or **Add as note**, the card's front/back, and the exact Pinyin as read — chooses between M3(a)(b)(c) and M8.
4. For 好像: the chip text (or "No clear reading…") — decides M4(a) vs (b) vs (d).
5. Page layout photo (stacked vs side by side, spacing) — decides M5 (1)/(2)/(4).
6. Whether `task/note-analysis` Debug output is available for the same page — optional corroboration only.

Until those arrive, M2/M3/M4/M5 remain "mechanism confirmed, trigger unconfirmed". Fixes for **confirmed** mechanisms (e.g. Stage 1) do not wait on screenshots; screenshots decide only which exact reproduction to bind and which unconfirmed trigger to chase. Do not write a fix for a guessed trigger.

---

## 10. Scope guard

No new features, no UI redesign. User-visible changes are limited to (a) chips scoped to the affected fields with a plain reason, (b) cards flagged/blocked when fields are unresolved. The font-like replacement look is tolerated as is. Notebook, canvas, home/cover, ink tools, Quizlet export format, and the non-vocabulary extractor kinds stay as they are.
