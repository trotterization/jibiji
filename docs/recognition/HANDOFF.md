# Recognition overhaul: handoff (checkpoint, work paused)

Written at a mandatory usage handoff. **No recognition-integrity repair code exists yet.** Everything below distinguishes what was observed on the real iPad from what was only tested synthetically.

## Branches, SHAs, PRs

| Item | Branch | SHA | PR | Status |
|---|---|---|---|---|
| Stage 1: Suggest reads only original ink | `task/recognition-overhaul-stage1` | `ca95ad8` | #23 (draft) | simulator tests with fake readers |
| Stage 2: Pinyin never becomes English (extractor/parse) | `task/recognition-overhaul-stage2-fields` | `a2cd9bb` | #24 (draft, base stage1) | same |
| Stage 3: pages read as grouped notes, per cell | `task/recognition-overhaul-stage3-grouping` | `308d4d0` | #25 (draft, base stage2) | **faulty; this is the build installed for testing** |
| Stage 4: per-note records (preserved) | `task/recognition-overhaul-stage4-records` | `5dbe626` (WIP on `0524c70`) | #26 (draft, base stage3) | `0524c70`: 258 simulator tests passed at that commit. `5dbe626`: **never compiled or run**. Not installed. Persistence is deferred. |
| Docs (this folder) | `task/recognition-integrity-docs` | see PR | docs only | no code |

`origin/main` was `69c1793` throughout. Nothing is merged. Stages 1 to 4 add tests that use fake readers; none exercised PencilKit, Vision or Paddle on real handwriting.

## Failing real-device scenario (observed on the iPad)

On a physical iPad Air (M4) running the stage-3 Debug build, the tester wrote the Hanzi 好 at the left and, well to its right, the Pinyin `hǎo xiang` (tone mark drawn as a separate small stroke above the `a`, a clear space between `hǎo` and `xiang`). Observed: Suggest showed the chip text `好 hňo`; the "Other readings" alternatives were nonsensical misspellings; the generated card was front `好`, back `hňo`, source text `好 hňo`. Read back from the app container afterwards (see below): the saved card holds exactly that. So:

1. `xiang` was already absent from the line text the card and Suggest used.
2. The misread Pinyin `hňo` became the card's English side.
3. The correct reading, available in the manual OCR view, was not used.

Flags read from the container preferences: `JibijiUsePaddlePipeline` = false; no `JibijiNoteGrouping` key (so the default, grouping on, was active). Geometry of the saved ink (offline, local only): the gap between `hǎo` and `xiang` is larger than the cell-merge limit in `NoteReading.mergedCells`, so they were separate layout cells (consistent with `xiang` being dropped or filed in another field); the caron stroke is a separate small stroke that a per-cell recogniser can read as a different letter. These conclusions come from reading code plus the real ink geometry; the exact per-cell OCR strings were not captured (no console log).

## Code-proven gaps (stage 3, commit `308d4d0`)

- No shared resolver: Suggest and Cards each reduce the OCR evidence differently; cards ignore alternate readings.
- Raw OCR readings are shown as "Other readings" and as the replacement text (readings fallback in `PageSuggestionModel.finish`). The only gate is `ReadingValidation`, a *shape* check that accepts `hňo`. No Pinyin/syllable/tone-structure check is applied to candidates.
- `HanziPrefixFallback` was built for a whole line (`好 hǎo xiang`); Stage 3 feeds it a Hanzi-only cell, so it can never accept. The whole-line Paddle reading that works in the manual view ("Run Pinyin OCR by line") is not used by Suggest/Cards.
- `PinyinSlot` near-match needs a romanization of 4+ letters, so short syllables (`hao`) still fall into the card's English field.
- The semantic layer is an 8-entry starter list plus heuristics. There is **no** AI or general dictionary review; do not describe anything here as one. No model or dictionary is configured that could provide general semantics.

## Next repair assignment (not started)

Create a repair branch from `308d4d0`. Outline and implement one corrected flow, described first in `docs/recognition/`:
1. One shared evidence collector per note region: keep spatial provenance (cells and strokes), and also read the *whole line* region with every engine (including the Paddle whole-line path) before any grouping decision. Do not drop separated Pinyin syllables; join same-row Latin cells into one Pinyin field.
2. One shared resolver used by Suggest **and** Cards. Inputs: all raw readings with source. Outputs: per-field status (confirmed, tentative, unresolved) with provenance.
3. Raw OCR readings are diagnostics only, never listed as dictionary suggestions. Candidate fields are validated: Hanzi characters only; Pinyin must parse as syllables with consistent tone marks; English must not be a romanization. Short syllables and English must not fall into each other's fields.
4. Unknown words stay unresolved (no English invented). Only real dictionary entries propose completions. Name what the dictionary is; do not claim the 8-word starter list is general Mandarin knowledge. Document, with sources, any semantic option; none is configured and none may be paid or uploaded.
5. Restore the Hanzi-prefix path using the observed whole-line ink readings, not fixtures.
6. Accepted edits are authoritative for cards.
7. Add a Debug diagnostic showing the commit/build identifier and active flags (build stamp), so an installed binary can be verified.
8. Regression tests from the real failing ink (kept local; see below) plus synthetic variants. Fresh reviewer, then a signed Debug build, install, and stamp verification.

## Evidence access (local only, not committed)

- App-container read access works: `xcrun devicectl device info files --device <UDID> --domain-type appDataContainer --domain-identifier <bundle id>` lists files and `devicectl device copy from` copies them. Notes live in `Library/Application Support/Notes/` (`page-N.drawing`, `page-N.annotations.json`, `page-N.flashcards.json`, `notebook.json`); flags in `Library/Preferences/<bundle id>.plist`. Read-only; nothing was changed or deleted.
- Actually retrieved (local copies, **private, never commit**): `page-5.drawing`, `page-5.flashcards.json`, `notebook.json`, the preferences plist, and a PNG render of the page-5 ink, in `work/jibiji-device-evidence-private/` next to the worktrees. A small offline PencilKit script that dumps stroke bounds is in `work/jibiji-audit-scripts/`.
- Not retrieved: console output of a Suggest run, `PKStrokeRecognizer.supportedLanguages` on the device, `page-5.annotations.json` (none existed).
- Build identity: the installed app is the only JIBIJI bundle (version 0.1, build 1); a binary hash cannot be read from the device, and the app has no build stamp. The installed artifact was built right after commit `308d4d0`.

## Worktrees

`work/jibiji-recognition-overhaul` (this repo's worktree, currently on the docs branch) holds all stage branches; earlier worktrees (`jibiji-install-main` baseline `69c1793`, `jibiji-current-main` = `task/note-analysis`, others) were left untouched. Gitignored local files (OCR models, signing config) were not committed.
