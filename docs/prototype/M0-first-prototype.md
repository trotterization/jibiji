# M0 · First prototype (issue #2)

> **Current status: feature scope is frozen; stabilizing existing behavior first, UI polish second.** The current objective and latest results are in [CLAUDE.md](../../CLAUDE.md). The sections below are the historical prototype record plus setup notes. Checkpoints marked historical are kept for evidence, and their "local, nothing pushed" statements describe the state at that time, not current publication directions.

**Latest simulator result:** 122 passed, 1 expected failure (Chinese recognition in the Simulator), 1 skipped, no unexpected failures. On the exact ink of the current end-to-end case, PaddleOCR mobile read the Pinyin correctly and simulator PencilKit missed 好. A real iPad build is installed. Completion and card creation end to end are still pending.

The first native JIBIJI build: one PencilKit page that captures ink, saves it locally, and reopens it after a relaunch, plus a small `PKStrokeRecognizer` feasibility check. AI suggestions and flashcards come in later issues.

## What the app does

- **One page** in SwiftUI with the system PencilKit tool palette: pens, eraser, lasso, ruler, undo, and redo. On iPad with a paired Apple Pencil the canvas follows the system “Only Draw with Apple Pencil” setting.
- **Autosave.** Ink is written 0.7 s after each writing pause and whenever the app leaves the foreground. The status line under the title shows the stroke count and whether the page is saved.
- **Original ink is kept as written.** Each page is stored as untouched `PKDrawing` data in `Application Support/Notes/page-1.drawing` with an atomic write. If a saved page can’t be decoded, the file is moved aside (`page-1.unreadable-…drawing`) instead of being overwritten. If it can’t be read for another reason, editing is paused.
- **All ink stays reachable.** If ink extends past the visible page, or would sit under the bottom tool palette (for example after writing in portrait and rotating to landscape), the page scrolls far enough to show it above the palette. Pages whose ink is already in view don’t scroll.
- **Recognition check.** The text-viewfinder button runs `PKStrokeRecognizer` on the current page. It shows availability, languages, recognized text, and latency. **Find in ink** shows how many strokes match and where they are on the page, and **Copy report** puts a plain-text summary on the clipboard for the PR. The tool palette hides while the check is open.

## Build and run

| | |
| --- | --- |
| Xcode | 27.2 (27B52), Swift 6.4.2, Swift 6 language mode |
| SDK | iOS 27.2 |
| Deployment target | iPadOS 26.0 (iPad only). Recognition needs iPadOS 27 and is availability-gated. |
| Simulator used | iPad Air 11-inch (M4), iOS 27.2 (24B8117) |

1. Open `JIBIJI.xcodeproj`, choose the **JIBIJI** scheme and an iPad simulator, then press ⌘R. Press ⌘U to run the tests.
2. From the command line:

   ```bash
   xcodebuild test -project JIBIJI.xcodeproj -scheme JIBIJI -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4),OS=27.2'
   ```

3. **Running on your own iPad:** copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and set your Team ID and a bundle ID prefix you control. Don’t choose a team in Signing & Capabilities, because Xcode writes it into the shared project file.

**Test notebooks (Debug builds only).** `-JIBIJIStoreName <name>` opens a separate, disposable notebook, and `-JIBIJIResetStore YES` empties it first. Names may use only ASCII letters, digits, and `-`; any other name stops the app rather than falling back to real notes. A test notebook always starts with the pen and doesn’t save tool-palette changes, so UI tests are repeatable and never change a student’s palette.

## Simulator results (iPad Air 11-inch (M4), iOS 27.2)

| Check | Result |
| --- | --- |
| Debug build (Simulator) and Release build (`generic/platform=iOS`, unsigned) | Pass, no compiler warnings |
| 35 unit tests (Swift Testing): save, reopen, repeated round trips, separate pages, erase-all, unreadable and unwritable files, autosave timing, test-notebook isolation | Pass. One documented known issue: Chinese recognition, below. |
| Stroke IDs (`PKStroke.id`, iOS 27) survive save and reopen | Pass |
| Canvas hosted in a window: opening a saved page shows it without reporting an edit, so nothing autosaves; ink beyond the view, e.g. after rotation, can scroll clear of the tool palette; ink that fits doesn’t scroll | Pass. These tests fail when the fixes are removed. |
| UI test: draw two strokes, wait for “Saved”, terminate, relaunch. The strokes are **rendered on screen** (pixel check) and Undo is off on the reopened page. | Pass. The pixel check fails on the pre-fix code. |
| UI test: palette Undo and Redo update and persist the page across a relaunch | Pass |
| UI test: the recognition check opens and finishes, the palette hides under it, and the palette returns afterwards | Pass |

The suite passed starting from the eraser as the remembered palette tool, and that tool was unchanged afterwards. UI tests use finger drags in place of Apple Pencil and are skipped on physical devices. Pressure, tilt, palm rejection, and Pencil Pro gestures need the hand checks below.

**Bugs found and fixed during testing:**

- A page assigned to `PKCanvasView` before its first layout loaded but didn’t render. The saved page is now applied after layout.
- Ink written beyond the current view (portrait, then landscape) couldn’t be scrolled to. The scrollable area now covers all ink, with room to scroll the lowest line above the tool palette.
- The tool palette stayed usable above the recognition sheet. It now hides while the sheet is open.
- An invalid test-notebook name silently used the real notebook. It now stops the app.

**Simulator quirk (tests only):** drags synthesized right after switching tools in the palette record strokes that don’t render. That’s why test notebooks start with the pen instead of having tests tap it.

## Recognition feasibility

Checked with machine-drawn synthetic ink in the iOS 27.2 Simulator. This isn’t evidence of handwriting quality.

| Question | Finding |
| --- | --- |
| Is `PKStrokeRecognizer` in the SDK? | Yes, iOS 27.0+, an actor with `recognizedText(strokeIDs:)`, `search(_:)`, and `indexableContent`. Recognition version 9. |
| Does it support Chinese? | **No (Simulator).** `supportedLanguages` lists 20 Latin-script languages (`cs, da, de, en, es, fi, fr, hi-Latn, id, it, ms, nb, nl, nn, no, pl, pt-BR, ro, sv, tr`). Requesting `zh-Hans` + `en` activates only `en-Latn-US`. |
| What came back for synthetic Chinese | 大人 → “kk”, 十三 → “+=”, 一二三 → nothing |
| Stroke and region references | Both observed. Text for a subset of stroke IDs: the strokes of 大 alone → “K”. Search: “kk” on the 大人 page → 1 match with 5 stroke IDs and bounds (87, 163, 204×90 pt). Searching “大” → no matches, as expected with no Chinese language active. |
| Latency (Simulator) | Cold first call 9.3 s (an earlier run that wasn’t kept took about 18 s). Warm 8–705 ms across four kept runs. One stroke in the recognition check: 9–24 ms. |
| Candidate fallback: Vision `RecognizeTextRequest` on rendered ink (test-only probe) | Lists `zh-Hans` and `zh-Hant`. Read rendered synthetic 大人 correctly (0.9 s warm). 十三 → “-三”, 一二三 → nothing. Promising enough to test on real handwriting. |

**Simulator limitation (not a device blocker):** the iOS 27.2 Simulator doesn’t offer Simplified Chinese stroke recognition through `PKStrokeRecognizer`. The physical iPad checked below did activate `zh-Hans-CN` with `en-Latn-US`, so this limitation applies to the Simulator only. The unit test records it with `withKnownIssue`, which flags if Chinese support appears in the Simulator.

On iPadOS 26 the recognition check reports “unavailable.” That path is compile-checked only, because no iOS 26 Simulator runtime is installed.

## Physical iPad checks: pending

No iPad was connected to the build Mac. On an iPad Air (M4) with Apple Pencil Pro, use synthetic notes only:

1. Write “fùzé” beside “responsible for?” and a few characters (负责, 虎头蛇尾). Wait for **Saved**, force-quit from the app switcher, and reopen. The ink should be identical.
2. Write a last line just above the palette in portrait, rotate to landscape, and scroll down. The line should come fully into view above the palette.
3. Confirm palm rejection, and that a finger doesn’t draw while “Only Draw with Apple Pencil” is on.
4. Check that squeeze and barrel roll on Apple Pencil Pro work with the tool palette, and that hover preview appears.
5. Tap the recognition check. Record whether `zh-Hans` is supported on the device, the active languages, recognized text against what was written, and latency. Try **Find in ink** with a word it recognized. Paste **Copy report** into the draft PR.
6. Run only the unit tests on the iPad, using the **JIBIJITests** bundle in the Test navigator (UI tests skip on devices). Note whether the Chinese known issue still records.
7. Fill most of a page and check save time in Console. Filter by subsystem `com.trotterization.jibiji` and category `notes`; the subsystem is the same whatever bundle ID you sign with.

## Physical iPad recognition evidence

Recognition check run on an iPad Air M4, iPadOS 27.0 (24A437), recognizer version 9. Only `zh-Hans-CN` and `en-Latn-US` were active, so Simplified Chinese was active on this device, unlike the Simulator.

| Sample | Strokes | Latency | Written | Recognized |
| --- | --- | --- | --- | --- |
| 1 | 35 | 353 ms | pǔ tōng, 你好 nǐ hǎo hello | “pu tong”, “你好 ni ho hello” |
| 2 (screenshot) | 31 | 65 ms | 你好, nǐ hǎo, hello, hi | 你好 correct. nǐ hǎo misread. hello and hi joined. Some accented letters survived, but acute and grave weren’t reliably distinguished. |
| 2 (copied on-device report) | 31 | 316 ms | Same 31-stroke sample | Exact text: `你好nř hňo hellohi a àà` |

**Copied report for sample 2 (same 31-stroke sample):** iPadOS 27.0 (24A437), recognizer version 9, active languages `zh-Hans-CN` and `en-Latn-US`. The bilingual configuration (Simplified Chinese plus English) is kept.

- **Two latency observations, not averaged.** The earlier screenshot showed 65 ms. The copied report shows 316 ms. They are separate measurements of the same sample, and no combined figure is given.
- **Languages.** The report lists 33 supported languages. None is a separate Pinyin or Chinese Latin locale. The diagnostic states that no separate Pinyin handwriting language is exposed on this iPad.
- **Accents.** In the copied text, the accented letters came back as ř, ň, and à, so some accent marks were produced, though not the intended ones (“nř hňo” for “nǐ hǎo”). This sample doesn’t show that accents are never recognized.
- **Scope.** These results are from one iPad on one OS build. They don’t generalize to other devices or OS versions.
- This note doesn’t show that saved ink survived a relaunch. Check 1 above is still pending.
- Two samples are anecdotal, not a quality measurement.
- **Baseline (standalone sample).** Intended text `mā má mǎ mà`, 13 strokes, 43 ms, iPadOS 27.0, bilingual setting unchanged. Exact PencilKit result: `mă má mama`. Its `mă` uses a breve (U+0306), not a macron or caron. This report has no Vision section, so the comparison is pending.
- **Standalone comparison (same intended text, `mā má mǎ mà`, 13 strokes, real device).** PencilKit (bilingual, unchanged): `mă má mama`, 43 ms. Vision standalone: `nà ná mà mà`, 168 ms, 1328×422 px rendered image. Neither reproduced the intended marks; both are single runs, not a quality measurement.

## Local standalone Pinyin OCR experiment (DEBUG, opt-in, PR #4)

A second, separate diagnostic in the recognition check: **Run Pinyin OCR on full drawing**. It is compiled only in Debug builds. It doesn't change the PencilKit baseline (`zh-Hans-CN` + `en-Latn-US`), the original ink, or the Vision diagnostic, and it makes no network calls.

**Scope.** Handwritten Pinyin on one line, or on two or more clearly separated horizontal lines (the button is **Run Pinyin OCR by line**, identifier `runPinyinOCR`). Not mixed Hanzi, English, and Pinyin pages, no columns or free-form layouts, and no region selection yet. The pen geometry is the line detector: the vertical intervals occupied by each non-tiny stroke's rendered bounds are merged, and a new line starts only across a blank band of at least 1.5× the median body stroke height (never under 24 pt), so detached tone marks and dots stay with their letters. Tiny strokes (under 4 pt) join the nearest line. Whenever it is unsure (fewer than two lines, a "line" of fewer than two body strokes) the whole drawing is read as one line, as before. Each line is cropped and recognized on its own, top to bottom, with the same cached sessions, and the raw outputs are joined with newlines. The report shows the line count and each line's crop size. No tone or spelling guessing. Output is raw model output: no word list, no hardcoded phrases, no tone guessing. A benchmark outside this repo (a local run, not reproducible from this repo alone) matched handwritten nǐ hǎo and standalone pǔ tōng exactly using this model with a tight ink crop plus 8 px or 16 px.

**Dependency.** [`onnxruntime-swift-package-manager`](https://github.com/microsoft/onnxruntime-swift-package-manager), exact version 1.24.2, product `onnxruntime` (`import OnnxRuntimeBindings`), linked into the JIBIJI target. Xcode resolves it on first open.

**Model and licence.** PaddleOCR PP-OCRv5_server_rec, official ONNX export, Apache-2.0. Model files are never committed; both are gitignored.

**Setup (local, per developer).** Copy these two files into `JIBIJI/Recognition/` with exactly these names. The synchronized folder bundles them into the app:

| File | Contents |
| --- | --- |
| `PinyinRecognition.onnx` | The PP-OCRv5_server_rec ONNX model |
| `PinyinRecognitionDictionary.json` | The model YAML's `character_dict` as a JSON array of strings, in YAML order. Multi-code-point entries stay as written. |

Class 0 is the CTC blank, class *k* is `dictionary[k-1]`, and the class after the last entry is the space character PaddleOCR appends. The model files are optional. Without them the button reports that the model is missing, the app still builds and runs, and Pinyin regions fall back to PencilKit or Vision output with weaker tone-mark accuracy. This fallback and the OCR experiments exist in Debug builds only. Only the server model's official source is linked under References; no verified download links are recorded for the exact mobile files, so none are given here. Never commit the files.

**Pipeline (follows Paddle's iOS demo).** The ink is recolored black and rendered on white at 2× (the scale of an iPad screenshot), cropped to the bounds of all strokes so detached tone marks are included, plus 8 px (4 pt) padding. Padding is applied at screenshot scale because that is the scale the benchmark's tight + 8 / tight + 16 px was measured at. The image is resized to 48 px high keeping its aspect ratio, converted to grayscale, replicated to RGB, and stored as CHW Float32 in [-1, 1]. Width is at least 320, padded with zeros on the right. Greedy CTC (blank 0) then Unicode NFC. Preprocessing and inference run on an actor, off the main thread. A result is dropped if the ink changes while it runs. The report shows output and elapsed time (the first run includes model load).

**Optional second output: PaddleOCR mobile (ink cleanup).** The same button also runs the PP-OCRv5_mobile_rec ONNX when `PinyinMobileRecognition.onnx` and `PinyinMobileRecognitionDictionary.json` are staged in `JIBIJI/Recognition/` (gitignored; otherwise it reports them missing). It uses its own cached session and the same input size and CTC decoding, and fails if the model's class count isn't `dictionary.count + 2`. The server result above is unchanged. For the mobile crop only: a stroke under about 4 pt that is more than 24 pt (rectangle to rectangle) from every other stroke and either lies entirely below the other ink, or sits no higher than the top of the written ink but horizontally outside its whole extent (a stray point beside or between lines), is left out (the saved drawing is untouched; tiny strokes near or above letters, and drawings with no larger stroke, are never dropped). Specks are removed before lines are split, then a 3×3 minimum filter grows the dark pixels 1 px at the native 2× resolution before resizing. No output corrections or lexicon.

**Replay test (opt-in).** Put a synthetic `LocalPinyinReplay.drawing` (gitignored) in `JIBIJITests/` and run `PinyinOCRTests/localReplayRunsBothModels`. It prints both models' outputs. With `TEST_RUNNER_JIBIJI_DUMP_REPLAY_PNG=1` it also writes the raw and cleaned native grayscale crops to the simulator's temp folder.

**Tests.** `PinyinOCRTests` covers the accented CTC round trip, input shape and padding, the empty drawing, and line splitting (two synthetic rows of unequal height with detached accents and a stray point, plus fallbacks to one line). An extra test runs the staged model on synthetic ink and is skipped when the model isn't bundled.

**Status.** Evidence is kept separate by what it shows:

| Evidence | What it shows | What it doesn't show |
| --- | --- | --- |
| Bench Mac, official PP-OCRv5 server ONNX, outside the app | Decoded exact NFC `nǐ hǎo` and standalone `pǔ tōng` on two manually isolated crops of real-ink screenshots (tight foreground bounds + 8 px or 16 px white padding). A plain, larger crop missed the macron in `tōng`. Printed `mā má mǎ mà` decoded exactly. | Not run inside the app. Not handwritten `mā má mǎ mà`: handwriting of all four tones is untested with Paddle, and we only have the prior PencilKit and Vision report from the iPad. Two crops are anecdotal. |
| JIBIJI in the iPad Air M4 Simulator, iOS 27.2 | The relevant tests passed with zero unexpected failures, including running the bundled model on synthetic ink. | Tests inference only. Not real handwriting, and not a quality or latency measurement. |
| Signed physical build | Built successfully. | Not installed: the physical iPad is currently unavailable. No on-device result yet. |
| Physical iPad, synthetic sample, server model (raw ink) | Output `Mā Má mǎMa`, 134 ms cold (includes model load). | One sample. Not a quality measurement. |
| Simulator, native PencilKit replay of the identical 13 saved strokes | Reproduced the device server output `Mā Má mǎMa`. The mobile model with ink cleanup removed one tiny detached stroke far below the line and read `mā má mǎmà`: all four tones correct, but a space is missing between `mǎ` and `mà`. | Simulator inference on one saved sample. Not a latency or quality measurement. |

**Latest by-line results (added after the earlier entries above, which are kept as history).**

| Evidence | What it shows | What it doesn't show |
| --- | --- | --- |
| iPad Air M4 Simulator: nine targeted tests | All nine passed, including replay of the 16 saved strokes (`mā má mǎ mà` above `hà`). Raw server output: `Mā Má MǎMà` newline `hà`. Mobile model with ink cleanup: `mā má mǎ mà` newline `hà`, an exact match to the intended text. The one stray point was excluded from the crop. | Simulator inference on one saved sample. Not a latency or quality measurement, and not proof on a physical device. |
| Signed build on the physical iPad | Installed and launched successfully. This supersedes the earlier "Not installed" entry in the table above. | Superseded by the verified physical by-line test below. |
| **Physical iPad Air M4, iPadOS 27.0 (24A437), 16-stroke by-line test (verified)** | Mobile model: exactly `mā má mǎ mà` newline `hà`, 413 ms reported for the first run (includes model load); 2 lines, crops 960×212 then 192×224 px; one isolated speck excluded. Server model: `Mā Má MǎMà` newline `hà`, 259 ms first run. PencilKit (active `zh-Hans-CN` and `en-Latn-US`): `má má mama` newline `ha`, 259 ms. Vision: `nà ná ma mà`, 131 ms. | One synthetic sample. The timings are first runs. Not a quality measurement. |
| **Physical iPad, mobile Pinyin OCR, user-reported warm observation** | The user reports 150 ms after first initialization, against the 413 ms initial run above. | A single user-reported figure, not independently captured here. No percentile claims (no p50 or p95) and no distribution. Not a quality measurement. |

**Earlier by-line baseline (kept for history).** The same real two-row page (16 strokes) fed to the models as one whole-page crop read `MhaMá Mǎnà` (server) and `m ǎ ` (mobile). Splitting by line is what the results above test.

**Pending.** The physical recognition check is now evidenced by the by-line test above. Still pending: the neutral tone (`ma`), broader mixed layouts and samples beyond the one verified mixed line, and an explicit physical force-quit ink check (check 1 above). All results come from a single synthetic sample, so they support no claim about accuracy in general.

**Mixed-ink region comparison and context-aware routing (DEBUG, manual; prior physical evidence).** One real handwritten 35-stroke line on a physical iPad (Hanzi 负责, its Pinyin, then English); the ink and the exact report text stay local and aren't reproduced here. Whole-line runs of the four recognizers (PencilKit, Vision, Paddle server, Paddle mobile) each misread part of the line, in 92–746 ms. The separate **Run context-aware routing (targeted Paddle only)** button works like this: PencilKit reads each region; only a region whose normalized letters exactly match Han-Latin output of the immediately preceding short Hanzi region counts as matched Pinyin; only that cropped region is sent to the mobile model; no output is inferred. **Simulator:** the strokes grouped exactly 14/7/14 and the mobile model read the Pinyin region correctly, but simulator PencilKit misread the Hanzi, so the routing path itself wasn't exercised there. **Physical iPad (iPadOS 27.0, 24A437), verified end to end from a copied device report:** the line split into three regions, only the Pinyin region was routed via the preceding 负责, the mobile model read it exactly, and the English region stayed with PencilKit. One page, one sample, not a quality measurement. This is the prior working physical routing evidence that the current objective in CLAUDE.md builds on.

**Local data.** The raw device sample (`LocalPinyinReplay.drawing`) stays local and gitignored. It must not be committed or published.

**References (official).**

- ONNX model: [PaddlePaddle/PP-OCRv5_server_rec_onnx on Hugging Face](https://huggingface.co/PaddlePaddle/PP-OCRv5_server_rec_onnx)
- iOS demo: [PaddleOCR `deploy/ios_demo`](https://github.com/PaddlePaddle/PaddleOCR/tree/main/deploy/ios_demo)

The earlier unpublished detached-tone-mark heuristic (`InkToneProbe`) was removed and replaced by this experiment.

## M1 checkpoint handoff (historical, branch `review/m1-local-notebook`)

Historical checkpoint: at the time it was written, this work was uncommitted and local.

**Built:**

- A Pages menu with New Page, and pages kept in a local indexed order.
- Independent autosave for each page.
- Undo applies to the currently open page only and resets when you switch pages. This is the current implementation.

**Verified:**

- The combined build was installed and launched on the iPad.
- The original Page 1 drawing was verified byte-for-byte before and after the upgrade.
- 56 simulator unit tests passed on the initial run, with the one expected known issue (Chinese recognition in the Simulator).

- On the physical iPad, the app's storage holds `notebook.json` plus separate `page-1.drawing` and `page-2.drawing` files.
- A recognition check on an English/symbol page (11 strokes, Saved): PencilKit read it correctly in 38 ms; Vision returned no text; both Paddle Pinyin experiments returned unrelated text. PencilKit is the recognizer to keep for non-Pinyin ink. One sample, not a quality measurement.

**Needs a rerun or is pending:**

- One UI ink screenshot assertion failed, and the simulator later stalled while idle. Rerun the UI tests.
- A Mac crash report at 9:54:43 PM is for Apple's `com.apple.InputUI` inside the Simulator, terminated by the FrontBoard scene-create watchdog. It is not a JIBIJI crash report. A separate fresh simulator attempt stalled before the tests started.
- The current physical app is still running. Physical Apple Pencil eraser and Undo checks are pending.
- Reopening both pages on the iPad (relaunch check) is pending.

**Handoff workflow for a ready milestone:**

1. Commit and push the task branch.
2. Open a draft PR with the evidence and the next action.
3. A teammate reviews it before merge.

## M2 checkpoint (historical, suggestions, branch `review/m1-local-notebook`)

Historical checkpoint, written while the work was uncommitted. **M2 is not claimed complete:** physical-iPad acceptance is pending.

**Built:**

- An on-demand **Suggest** button. Nothing is suggested automatically.
- A local vocabulary of six entries. No network calls.
- Input is real PencilKit ink.
- Each suggestion is a note anchored to the handwriting it was made from.
- Accept, edit, dismiss, alternatives, and undo.
- Annotations are stored in a per-page sidecar written atomically. A pending suggestion is invalidated when its source ink changes.
- Existing correct Hanzi can receive a gloss only; the Hanzi is not rewritten.

**Verified:**

- Release simulator build succeeded.
- Signed Debug iPad build succeeded.
- Simulator `JIBIJITests`: 81 passed, with 1 existing expected failure (Chinese recognition in the Simulator) and no unexpected failures. The M2 suites were verified.
- The build was installed and launched on the iPad.

**Latest verification (Nov 15):**

- Simulator unit tests: 82 passed, 1 existing expected failure (Chinese recognition in the Simulator), and 1 opt-in physical replay test skipped in the Simulator.
- Release simulator build passed.
- Claude implemented reversible display of an accepted note when its source ink is erased. The stored note is unchanged, and the note reappears when the ink returns.
- The opt-in physical test uses the existing gitignored 35-stroke fixture. The UI test uses a separate, seeded test notebook.
- Xcode couldn't launch the app while the iPad was locked. Physical acceptance and UI verification are still awaited.

**Pending (physical iPad):**

- The actual overlay, scrolling, and tool-palette interaction.
- Acceptance of the whole M2 flow on the device.

**Using existing notes:** an existing page with correct Hanzi can be used as it is for a gloss, with no rewriting. A sample without Hanzi is needed later to test the whole-suggestion path. Approved synthetic examples for docs and tests: 好像 and 负责.

## M3 checkpoint (historical, flashcards, branch `review/m1-local-notebook`)

Historical checkpoint, written while the work was uncommitted. It uses no cloud service. **M3 is not claimed complete:** physical UI acceptance is pending and live Quizlet import is unverified.

**First slice (what it specifies):**

- **Cards menu per page.** Each page has its own Cards menu. Nothing is extracted automatically.
- **On-demand extraction.** Choosing it reads that page's PencilKit ink, one line at a time, and makes draft cards for explicit:
  - vocabulary
  - idioms
  - grammar and examples
  - components and inline arrows
  - Classical Chinese
- **Ambiguity and drafts.** A line that can be read more than one way is shown as an ambiguous draft with its readings. Nothing becomes a card until the student chooses.
- **Edit, approve, discard.** Each draft can be edited, approved, or discarded. Only approved cards are studied or exported.
- **Study.** Approved cards can be flipped and moved to the next card.
- **Quizlet export.** Approved current cards can be copied as UTF-8 text, tab between term and definition and newline between cards, or saved as a `.txt` file for Quizlet's import box. Drafts, discarded cards and cards whose source changed are left out.
- **Stable deduplication.** Extracting again doesn't duplicate a card. Cards are deduplicated by the normalized extracted original front, back and kind, and the student's edits are preserved.
- **Review after changed source.** If the ink behind a card changes, the card is marked for review and isn't exported until the student approves it again.

**Design rules:**

- **One deck per page.** A page's cards live in that page's own deck. Decks aren't merged across pages.
- **Source text and bounds.** Each card stores the text it was read from and the bounds of that source on the page.
- **Deterministic ink fingerprint.** Change detection uses a deterministic content hash of the ink, including the bitmap mask. Any edit to the page can mark its cards for review, even if the edit is elsewhere. This favors extra reviews over stale cards.
- **Single line only.** Each card comes from one line. No source is inferred across lines. Freeform arrows that cross lines aren't read and make no cards. Only inline arrows within a line count.

**Verification:**

- Full simulator suite: 102 passed, 1 existing expected failure (Chinese recognition in the Simulator), and 1 opt-in device test skipped.
- 21 targeted flashcard tests passed after the final bitmap-mask fingerprint revision.
- A signed build was installed on the physical iPad. The launch timed out, so the physical UI check is pending.

**Pending:**

- Physical UI check on the iPad, including real handwriting, Apple Pencil, and the Cards menu.
- A live Quizlet import of an exported file. This is unverified.

## Next action

**Current first objective (supersedes the order below):** the physical-iPad end-to-end run in [CLAUDE.md](../../CLAUDE.md): mixed Hanzi/Pinyin with tones/English plus standalone marked Pinyin; on any page (for example Page 4) write `好 hǎo xiang`, propose 像 with “to seem like; to look like”, accept or edit, create the card with the approved English, and verify preserved ink, reopen, undo, review, and export. Simulator status: 122 passed, 1 expected failure, 1 skipped, no unexpected failures. Real iPad build installed; completion and card end to end pending. No new features until this passes.

Earlier list, kept for the remaining checks:

1. **Physical M2 UI verification.** Unlock the iPad, then run the opt-in physical replay test and the seeded-notebook UI check, and accept the whole M2 flow on the device (overlay, scrolling, tool palette, and the reversible accepted-note display when ink is erased and returns). Alongside it, the remaining M1 physical checks stay pending: Apple Pencil eraser, Undo, and reopening both pages after a relaunch. The other pending items above (neutral `ma`, broader mixed layouts and samples, force-quit ink check) can be run at the same time.
2. A teammate with the iPad also runs the other checks above and records the results in the draft PR.
3. The team chooses the recognition direction for Chinese and Pinyin tone marks, given the device evidence above, in a new issue. Candidates: Vision on rendered ink regions (anchored with stroke IDs from PencilKit), or a cloud provider with consent. Measure each on real mixed notes for quality, latency, privacy, and mainland China availability.
