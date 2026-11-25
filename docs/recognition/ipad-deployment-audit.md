> Status: audit of the stage-3 build installed for testing. Machine/user identifiers removed. Superseded in detail by `HANDOFF.md` in this folder.

# JIBIJI iPad deployment audit

Scope: read-only audit. No app edits, builds, test runs or installs were done for it. Code citations are from `git show 308d4d0:<path>`, the exact commit the installed binary was built from, not from the worktree. All file paths are relative to the repo root.
Tag key: **[VERIFIED]** checked directly in this audit. **[CODE]** follows from reading the shipped code but was not run on the iPad. **[UNKNOWN]** cannot be established from here.

## 1. What is on the iPad

| Item | Finding |
|---|---|
| Device | UDID `<device UDID>`, iPad Air 11-inch (M4) `iPad16,8`, paired and available **[VERIFIED]** |
| JIBIJI apps installed | Exactly one: `<bundle-prefix>.jibiji`, display name `jibiji`, version 0.1, build 1, `builtByDeveloper: true`. No duplicate bundle identifiers. **[VERIFIED]** |
| Install location | `/private/var/containers/Bundle/Application/<container id>/JIBIJI.app/`. This is the same path my stage-3 install printed. My earlier install (after Stage 1) printed a different path (`<earlier container id>…`), so each install changes the path. The unchanged path therefore indicates nothing has been installed since my stage-3 install. **[VERIFIED]** It is not proof of the binary contents. |
| Artifact I installed | `work/jibiji-recognition-overhaul-device/Build/Products/Debug-iphoneos/JIBIJI.app`, Debug configuration. The main binary and `JIBIJI.debug.dylib` are dated 19:01:18 and 19:01:17. The binary UUID is `B29A575C-00DD-3340-82F5-B113B5AC7364` and the debug dylib UUID is `73939AC5-1261-39E4-8070-56420EF1EA20`. Bundle ID, version and build number match the device. Team `<team id>`, `Local.xcconfig` bundle prefix `<bundle-prefix>`. **[VERIFIED]** |
| Source of that artifact | Commit `308d4d0` ("Stage 3 review fixes…") on `task/recognition-overhaul-stage3-grouping`, committed 19:01:00. The device build ran after the commit, and the log is dated 19:01:18. So the artifact was built from stage 3, which contains Stages 1, 2 and 3. **[VERIFIED by timestamps and command order]** |
| Bundled optional models | The artifact contains `PinyinMobileRecognition.onnx`, `PinyinRecognition.onnx` and both dictionaries. They are gitignored local files copied in from the earlier worktree. **[VERIFIED]** |
| Can the binary be proven? | **No.** `devicectl` exposes bundle id, version, build number and install path, but no binary hash or UUID of the app on the device. The 19:01 build, the install path continuity and the single-bundle result agree, but I cannot prove byte identity with the artifact above. The only way to prove it is a reinstall after verifying a UUID, or a stamped build identifier shown in the app. The app has no visible commit or build stamp, and both `CFBundleVersion` and `CFBundleShortVersionString` are constants, so a "matching version" proves nothing about the commit. **[UNKNOWN]** |
| Not on the device | Stage 4 (local commit `0524c70` plus uncommitted edits in the worktree). It was never pushed or installed. It was only run in the Simulator. **[VERIFIED]** The stage-4 worktree also holds 4 modified, uncommitted, unvalidated files (about 96 lines changed). They were left alone. The last test run before the interruption was green on the committed stage 4 only. |
| Runtime state on the device | Not read: UserDefaults (`JibijiUsePaddlePipeline`, `JibijiNoteGrouping`), build logs, `PKStrokeRecognizer.supportedLanguages`, the notebook files. **[UNKNOWN]** The Paddle opt-in switch lives in the Check recognition sheet (`RecognitionCheckView.swift:13`, default off), so whether the tester turned it on is unknown. |
| GitHub | PRs #23, #24 and #25 are open drafts, none merged. `origin/main` is still `69c1793`. There is no remote stage-4 branch. |

So the right build was probably the one on the iPad: Debug, stage 3, with the models. I cannot rule out that the tested build differed. The caveat on identity is real, because nothing in the app tells the tester which commit they are running.

## 2. What is actually active in the installed build (stage 3, Debug)

Flow when Suggest is tapped (`NotePageView.swift` → `PageSuggestionModel.request`):

1. **Generated ink removed** (Stage 1), then `PencilInkLineReader.lines` (mode `.suggestions`). **[CODE]**
2. **Reader selection.** If the `JibijiUsePaddlePipeline` default is on, the Paddle pipeline is used. Otherwise, if iPadOS 27 PencilKit supports zh-Hans, per-cell reading with PencilKit. Otherwise per-cell Vision. `NoteReading.isEnabled` is true by default, so **grouping is active** unless the default `JibijiNoteGrouping` is set false. **[CODE]**
3. **Per cell** (`NoteReading.lines`): `NoteLayout` cells, tight same-size neighbours merged, each cell read by itself, then `NoteGrouping` links cells into Hanzi/Pinyin/English entries. **[CODE]**
4. **Cell read** on the PencilKit path: PencilKit text for that cell only, then `HanziPrefixFallback` (Debug only), then Vision `lineReadings` of that cell as "readings". The Paddle mobile model joins only through Vision's `readCrop`, and only when Vision found exactly one line (or none). **[CODE]**
5. **Entry → line.** The text is Hanzi + Pinyin + English fields joined. The cell alternatives are re-parsed into whole-entry variants. **[CODE]**
6. **Cross-check** (`ReadingCrossCheck.resolve`): corrects an invalid Pinyin word only when another reading has the same Hanzi runs and the same word count, is valid Pinyin, and fits the romanization of the written Hanzi. Otherwise it flags the line as unresolved. **[CODE]**
7. **Proposal** (`finish`): first try `StarterVocabulary.proposal(forRecognizedText:)`, which has **8 entries** (`StarterVocabulary.swift:68-77`). If there is no entry match, the *readings fallback* (`PageSuggestionModel.swift`, the branch that builds `SuggestionCandidate(hanzi: reading, pinyin: "", gloss: "")` from every OCR reading) applies whenever the readings differ in Hanzi or the line is a single character. **[CODE]**
8. **Display.** For lexicon proposals the chip shows `candidate.hanzi · written Pinyin · gloss`. For fallback proposals the chip shows the **raw OCR string** as the replacement text, and the "Other readings" menu lists `candidate.hanzi` for every candidate (`SuggestionOverlay.swift:205-207`). **[CODE]**
9. **Cards.** `FlashcardsView` → `PageFlashcards.refresh` (mode `.primaryOnly`): same per-cell reading, but without the Hanzi-prefix pass. An accepted note produces a card from its stored fields. Every other line goes to `FlashcardExtractor` using the primary text only; `readings` and `alternatives` are not consulted there. **[CODE]**

### Answers to the specific questions

**Are raw OCR strings exposed as validated Mandarin alternatives?** **Yes, [CODE].** Nothing validates them as Mandarin. In the readings fallback, each OCR reading becomes a candidate "word". The only gate on those strings is `ReadingValidation.isWellFormed` (my Stage 1 addition), which checks the *shape* of tokens (no letter+digit soup, no control characters) and **does not check that Pinyin is Pinyin**. `hňo` is letters with a diacritic, so it passes. My Stage 1/PR text said malformed mixed OCR "is not offered as a word"; that only holds for digit/letter mixtures, not for misspelled Pinyin. The syllable table (`ReadingCrossCheck.syllables`) exists but is not applied to candidates.

**Is "好 hňo" explained by this code?** It is consistent with it, **not proven**. A lexicon proposal for 好 + Pinyin would display `好像 · …` (the completed word). A chip reading plain `好 hňo` is what the readings fallback produces: `candidate.hanzi` = the whole OCR string. That requires no lexicon match for the line text (an invalid "hňo" prevents it, `StarterVocabulary.swift:155-213`) and the fallback condition above. "Replace" would then write that misspelled OCR string as clean ink. The nonsensical "alternatives" are the other raw readings in the same menu.

**Are correct OCR candidates discarded?** Likely, in three code paths **[CODE]**:
- **The manual OCR view is a different pipeline.** "Run Pinyin OCR by line" and "context-aware routing" in the Check recognition sheet (`RecognitionCheckView.swift:276-293`) run Paddle (server + mobile) on the whole drawing or whole line. Suggest and Cards read **per cell** with PencilKit as primary and Paddle only as an occasional alternative through Vision. A correct Paddle reading visible in the manual view is therefore not what Suggest is shown. The Paddle context-aware routing for Latin cells that match the Hanzi's romanization (`PencilNoteCellReader` on `task/note-analysis`) was **not ported** into `NoteReading`.
- **`HanziPrefixFallback` is functionally dead after Stage 3.** It was designed to re-read a whole line like `好 hǎo xiang` with Paddle and accept the result only when the vocabulary matches it exactly (`HanziPrefixFallback.accepts`). Stage 3 hands it a Hanzi-only *cell* (`好`). A Paddle reading of one character has no Pinyin, so the vocabulary cannot match it and the fallback never accepts. The only mechanism that recovered `好 hǎo xiang → 像` on the physical iPad (prior evidence, M0) was weakened by my Stage 3. **This may be a regression I introduced.**
- **Alternatives are consulted only by the narrow cross-check** (same Hanzi runs and same word count). If the Pinyin cell and the Hanzi cell are read with different word counts, or `xiang` ends up in a different cell, the correct alternative is ignored.

**Does segmentation lose "xiang"?** **Possible, [CODE], not observed.** `NoteReading.mergedCells` merges adjacent cells only when the gap is a `tightGap` (under max(24 pt, scale)) and the size ratio is under 1.6. A word space in `hǎo xiang` at or above that limit leaves `hǎo` and `xiang` as separate cells. Grouping then attaches `hǎo` as Pinyin to 好, and `xiang` has no tone mark, so it is held as `ambiguousLatin` and goes to the English slot or becomes a Hanzi-less orphan entry (`NoteGrouping.entries`). That would produce a note whose Pinyin is only `hǎo`. The reviewer of Stage 3 predicted exactly this class of failure, and the fix I made handled tight gaps only. No test used real handwriting spacing, only synthetic strokes at chosen gaps. Whether this happened on the iPad is unknown.

**Do cards use the right Pinyin?** **No, [CODE].** Cards never consult alternates. For 好 with a misread syllable, `FlashcardExtractor.vocab` puts the misread text in the card. My Stage 2 near-miss rule requires a romanization of at least four letters (`PinyinSlot.minimumLengthForNearMatch`, so "has" is not read as a misread "hǎo"). That means for a short syllable like `hao` a misread (`hno`) is **not** recognised as Pinyin, `consumed` stays 0, and the whole Pinyin string lands in the back of the card as the definition. This is the user's original "Pinyin as English" failure, still reachable for one-syllable and short words. Separately, cards are built from accepted notes only if the note was accepted and matched; otherwise from raw primary text. The Hanzi-prefix completion (好 → 好像) lives only in Suggest, so a card for an unaccepted partial note cannot get 像.

## 3. Requirements versus the installed build

| Requirement | State in the installed build (stage 3) | Evidence |
|---|---|---|
| Replacement not re-corrected on the next Suggest | **Implemented, active** (Stage 1). Unverified on the iPad. | **[CODE]**, simulator tests with a fake reader |
| Repeat Suggest is idempotent; accepted notes stay quiet | **Partial.** Accepted notes are matched by stroke identity. Skipped suggestions are **not** remembered (that is in the uninstalled Stage 4). | **[CODE]** |
| Several notes; others not missed after one suggestion | **Partial.** Grouped per cell. The other-notes-missed failure was not reproduced or measured. Pending chips are all cleared on any ink change (the per-note retention is in Stage 4, uninstalled). | **[CODE]** |
| Stacked and side-by-side Hanzi/Pinyin/English grouping | **Partial, active.** Geometry grouping exists and is tested on synthetic strokes only. Real handwriting spacing, tone-mark diacritics as separate small strokes, and per-cell recognition quality are untested. | **[CODE]**, synthetic tests |
| Missing Hanzi/Pinyin/English completion | **Partial.** Only via the 8-entry lexicon (`负责 承担 预习 复习 虽然 但是 好像 农夫市集`), and only when the line text is clean. Unknown words are abstained or offered as raw OCR candidates. | `StarterVocabulary.swift:68-77` |
| Independent per-field validation | **Absent.** There are no per-field statuses (confirmed, tentative, unresolved). There is a shape check on whole strings and a toneless-syllable table used in one cross-check. Pinyin validity is not required of any candidate. | **[CODE]** |
| Dictionary alternatives | **Absent beyond two lexicon entries** that declare alternatives (负责↔承担). Everywhere else the "Other readings" menu shows raw OCR strings. | `SuggestionOverlay.swift:205`, fallback branch |
| OCR reconciliation across engines | **Partial/narrow.** One rule (`ReadingCrossCheck`), same Hanzi and word count. The Paddle whole-line reading of the manual view is not reconciled with per-cell reads. | **[CODE]** |
| Tone validation | **Partial.** Written tone vs lexicon Pinyin (missing / wrong / possible spelling) only when the word is in the lexicon. Not for unknown words. | `StarterVocabulary.toneState` |
| Cards from accepted fields | **Implemented for accepted notes** (Stages 1-2). Not for unaccepted notes, which are built from primary OCR text. Misread short Pinyin can still land in the English side (above). | **[CODE]** |
| Cards stale only with their own note | **Not in the installed build.** It is in the uninstalled Stage 4. | local commit `0524c70` |
| Field-scoped correction (affect only the changed fields) | **Absent.** Replace rewrites the whole line's strokes. Never started. | `NotePageModel.replaceSuggestion` |
| Migration of old pages/cards | **Partial.** New fields are optional and old files load. Behaviour with real old notebooks is untested. | **[CODE]** |
| Semantic or AI verification | **Absent.** There is no AI or semantic review anywhere. What exists: an 8-entry lexicon, edit-distance rules, syllable-table checks and geometry heuristics. None of that is an "AI review system" and none should be described as one. | — |

## 4. What my earlier reports got wrong or overstated

- "Malformed mixed OCR is not offered as a word" (Stage 1) is true only for digit/letter mixtures. Misspelled Pinyin such as `hňo` is still offered.
- Test counts (up to 258 passing) used fake readers or injected cell text. **None exercised PencilKit, Vision or Paddle on real handwriting.** They show the logic runs, not that recognition works. I did not state the Stage 3 per-cell change could regress the prior device evidence; it can.
- "Installed in place" was reported without proof of binary identity, and the app shows no build stamp.
- Stage 3 changed the recognition input granularity (whole line → cells) for both Suggest and Cards on the strength of simulator tests and a design argument, with no device comparison.

## 5. Missing pieces and risks, in order of likely impact on the reported failure

1. Pinyin validity is never checked on a candidate; raw OCR readings are shown as replacement text and alternatives.
2. Stage 3 per-cell reading probably disabled the Hanzi-prefix Paddle fallback and bypasses whole-line Paddle readings that the manual view shows.
3. Cell segmentation of `hǎo | xiang` is gap-dependent; `xiang` may be separated from its Pinyin field.
4. Cards ignore alternate readings, and short Pinyin misreads still fall into the English slot.
5. No build/commit identity visible in the app; no on-device logging of which reader, flags or cells were used for a Suggest.
6. No real-handwriting regression set; no device measurement of per-cell vs whole-line accuracy.

Evidence that would settle the open items (none gathered here): the app's `UserDefaults` flags, `PKStrokeRecognizer.supportedLanguages` on the device, a console capture of one Suggest (the Debug build prints HanziPrefixFallback lines), the saved `<page>.annotations.json` / `.flashcards.json` for the tested page, and the exact tap that produced `好 hňo` (chip text versus menu).
