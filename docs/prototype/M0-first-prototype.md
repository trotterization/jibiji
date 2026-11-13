# M0 · First prototype (issue #2)

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

**Blocker:** stroke-based recognition of Simplified Chinese isn’t available through `PKStrokeRecognizer` in the iOS 27.2 SDK as observed in the Simulator. Pinyin without tone marks and English may work through the Latin-script languages. The device may report a different language list, so that’s the first thing to confirm on the iPad. The unit test records it with `withKnownIssue`, which flags if Chinese support appears.

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

## Next action

1. A teammate with the iPad runs the checks above and posts the results in the draft PR.
2. The team chooses the recognition direction for Chinese, given the blocker, in a new issue. Candidates: Vision on rendered ink regions (anchored with stroke IDs from PencilKit), or a cloud provider with consent. Measure each on real mixed notes for quality, latency, privacy, and mainland China availability.
