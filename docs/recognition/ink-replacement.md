# Handwriting replacement UX

Accepting a suggestion now replaces the matching source strokes with clean handwriting-style PencilKit ink in the same region. It does not add a text sticker below the line.

## Student flow

- Tap **Suggest**. Each line with a suggestion gets a dashed outline and, just under it, a chip with the clean text and a **Replace** button.
- Tap **Replace** to swap the outlined strokes for clean handwriting in the same place. The chip's **…** menu has other readings, **Edit…** (type the text yourself), and **Skip**.
- The clean text is the Hanzi, plus the pinyin and English only if the line had some. For `好 hǎo xiang` it is `好像 hǎoxiàng`.
- Right after a replacement, a small chip under it offers **Restore** (bring back the original strokes) and **Delete**. It goes away when you write again. The notebook bar keeps both actions for the most recent intact replacement.
- The replacement is normal drawing content: use the eraser or lasso.
- Native Undo/Redo works for the replacement. Restore is also available after reopening the saved page.

The dashed source outlines do not intercept writing. Existing legacy annotations retain a visible Delete control. Independent remaining suggestions stay available after accepting one; overlapping/stale suggestions are dropped.

## Recovery and data

The accepted receipt stores the removed strokes, their ordering, and the replacement's stable geometry fingerprints. Recovery metadata is saved before original ink is removed. A metadata-save failure leaves the original untouched. Drawing saves use the existing atomic page storage; a failed drawing save remains retryable with the receipt retained. Restoration preserves later, unrelated writing. Existing note files remain readable because replacement receipts are optional fields in the annotation format.

Confirmed replacement text is used as a source for flashcards. The app must not reinterpret font-fill trajectories as new human handwriting and override an accepted word. Erasing or otherwise changing the generated glyph invalidates its exact fingerprint for confirmed-card purposes. Native Undo remains the recovery route for partial erasing.

## Rendering

LXGW WenKai TC provides a clean handwriting typeface. Core Text lays out the text and resolves fallback glyph fonts. Each glyph becomes a PencilKit ink stroke clipped to its outline, so the result supports native editing and has no opaque background. Original ink color and the source region are retained. PencilKit's serialized precision is canonicalized before recording fingerprints. Synthetic sample times are in the past so snapshots render completed strokes.

This cleans the displayed writing; it does not improve recognition accuracy or imitate an individual writer's style. It requires user review before changing ink.

## Font attribution

Bundled unchanged font: `JIBIJI/Assets/Fonts/LXGWWenKaiTC-Regular.ttf`.
Source: https://github.com/google/fonts/tree/main/ofl/lxgwwenkaitc
License: SIL Open Font License 1.1; the accompanying `OFL.txt` includes its copyright notices and terms.

## Verification

Tests cover visible rendering, font registration, glyph clipping, matching source strokes without deleting crossing arrows, failed-save preservation, keeping neighboring/later writing, restoration after relaunch, native Undo/Redo, deletion persistence, and confirmed-text flashcards. A deterministic UI fixture is restricted to Debug disposable test notebooks. The simulator UI test replaces a word, undoes/redoes it, deletes it, and restores the original after relaunch. The opt-in physical replay test now follows the replacement UX rather than the old annotation-chip flow. Physical iPad and Apple Pencil validation remains pending.
