# Debug Note Analysis: iPad walkthrough

Debug builds only. In Debug, the toolbar's separate **Cards** and **Check recognition** buttons are replaced by one **Note analysis** button. Release builds are unchanged. Use synthetic notes only.

## Try it (physical iPad Air M4, Apple Pencil)

1. Build and run the Debug scheme on the iPad (your own `Config/Local.xcconfig`).
2. On any page, write several vocabulary entries close together:
   - stacked: Pinyin directly above Hanzi, English below;
   - side by side: two entries on one row;
   - one partial entry, for example `好 hǎo xiang` with no English.
3. Tap **Note analysis**. It starts analyzing as soon as it opens; there is nothing to press.
4. Check the screen:
   - **Summary**: strokes, rows, cells, reading and total time.
   - **Problems**: unsupported OS, unreadable cells, or a cancelled read. Writing is never blocked.
   - **Source regions**: your ink with one colored box per entry field.
   - **Entries**: Hanzi, Pinyin and English per entry, `missing` in red, a tentative suggestion (for `好 hǎo xiang`: 好像, “to seem like; to look like”), and orange uncertainty notes. Nothing is accepted from here.
   - **Layout candidates and raw text**: each cell's PencilKit text, any Paddle refinement, and gap evidence.
   - **Flashcards**: counts, and **Open cards** to review, edit, study or export as before.
5. **Copy report** puts a plain-text report on the clipboard. Paste it into the draft PR, noting iPad and Simulator results separately.
6. **Done**, then confirm the ink is unchanged and existing cards are intact. Force-quit and reopen to confirm.

## What to record

- Entries grouped wrongly (stolen or missing fields), and the spacing that caused it.
- Pinyin read wrongly, especially tone marks. Paddle mobile only runs where the Pinyin matches the neighboring Hanzi, and only if its model files are installed (see START-HERE.md).
- Reading and total time.

## Known limits

- The Simulator cannot read Chinese ink, so expect missing Hanzi there. Device results are the evidence.
- Layout proposes cells. Where spacing is close, final grouping relies on the recognized text and says so in the uncertainty notes.
- Suggestions come from the small offline starter vocabulary only.
