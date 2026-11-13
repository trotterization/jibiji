# JIBIJI — Claude Code project instructions

## Start here

The first development task is [issue #2 — Create the first JIBIJI Xcode prototype](https://github.com/trotterization/jibiji/issues/2). Read it before editing. It authorizes a brief audit followed by creating the actual native Xcode project and a minimal PencilKit experiment. The deliverable is a draft PR the next teammate can continue.

On a Mac with Xcode and Claude Code installed, clone or update this repository and start Claude Code from the repo folder. Run /memory to confirm this file is loaded. Paste:

> Read CLAUDE.md and https://github.com/trotterization/jibiji/issues/2. Check my Xcode setup, then create the first native iPad SwiftUI Xcode project and the scoped PencilKit prototype on a new branch. Verify what you can and publish a draft PR with test results and a handoff. Stop before merging.

## Session rules

- Check the repo, current branch, and working tree. Read the assigned GitHub issue, linked PR, and overlapping open work before editing. If the issue cannot be accessed, ask for its text. Preserve teammates’ changes.
- Use one assigned issue and one branch per task. Work only on its scope and acceptance checks. Respect Plan-only mode when specified. Ask the team before expanding scope or editing a shared file or interface that another task has claimed.
- At startup, state the issue number, mode, files or components you expect to touch, and checks. Re-read the issue and latest handoff after a resume or context compaction.
- Work locally on a task branch. When the issue and developer authorize publishing, check the diff, commit, push the task branch, and open or update a draft PR. Leave merging to teammate review. If GitHub write tools are unavailable, give the developer the branch and draft PR text.
- Preserve branding assets and original note ink. Keep API keys, personal signing settings, and private classroom scans out of this public repo. Use synthetic examples in public issues, fixtures, and PRs.

## Team workflow

Use GitHub issues and draft PRs as the shared record. Each developer uses their own checkout, GitHub identity, and Claude session. Assign one owner per issue and one writer per branch. Start a new task from current main. Continue a handed-off task on its existing branch once it has been reassigned.

Each issue should state its owner, outcome, allowed files or components, acceptance checks, stop point, and whether Claude may commit, push, and open or update a draft PR. At the start, post or paste a short claim naming the area and expected checkpoint. Update it for a blocker, scope change, or handoff. Agree on ownership before two tasks change the same interface or Xcode project settings.

A draft PR should link its issue and record what changed, how to build or run it, simulator and iPad results separately, pending checks, and the exact next action. To take over, read the issue and draft PR, fetch its branch, and give Claude both links. Update shared requirements and milestone decisions in a separate reviewed change. Pull merged main before starting follow-up work.

One developer owns the initial Xcode project. Teammates can prepare sample notes and design references in parallel. Once interfaces are agreed, functionality and visual polish can proceed on separate issues and branches.

## Product requirements

JIBIJI is a handwriting-first Mandarin class notes app. Build the native iPadOS app in Xcode with Swift, SwiftUI, and PencilKit. The target device is an iPad Air (M4) with Apple Pencil Pro. Validate writing and recognition on the physical iPad.

- Preserve freeform pages containing Simplified Chinese, pinyin with or without tone marks, English glosses, incomplete phrases, arrows, circles, and marginal annotations. Save and reopen original strokes even when recognition or AI is unavailable.
- After a writing pause or on request, show quiet, visibly provisional inline completions or corrections next to the relevant ink. Support accept, reject, edit, alternatives, and undo. Keep accepted annotations separate from original strokes. Drop or re-evaluate a result if the source changes. Leave uncertain text unresolved when appropriate. A small library of handwriting-style fonts is a low-priority refinement.
- From a selected page or passage, automatically generate editable, source-linked drafts for vocabulary, idioms, grammar, examples, character components and related words, and Classical Chinese or register annotations. Respect clear arrows and labels and flag ambiguity. Allow edit, approve, discard, grouping into decks, and basic iPad study. Flag cards for review if their source changes.
- Export approved cards as UTF-8 tab-separated text for [Quizlet’s website importer](https://help.quizlet.com/hc/en-us/articles/360029977151-Creating-sets-by-importing-content). Use one front/back pair per line and normalize embedded separators. Verify that Chinese and pinyin survive import.
- Later milestones include iPhone access to study saved cards, richer review tools, and optional reorganized page previews. Automatic reorganization, daily recaps, and general-purpose cross-platform handwriting are outside the MVP.
- Verify SDK support before choosing a recognition approach. Keep runtime providers open until quality, latency, cost, privacy, and mainland China availability have been tested. Obtain consent before sending notes to a cloud AI provider.

| Example | Expected result |
| --- | --- |
| fùzé beside responsible for? | Tentatively offer 负责 and the gloss “to be responsible for” |
| 预 highlighted in 预习, arrows to related vocabulary | Preserve explicit links and flag ambiguous arrows |
| 与 = 和 (古汉语) | Draft a card with the gloss qualified to that Classical Chinese example |
| 虎头蛇尾 with a usage note | Preserve the idiom and written usage |
| 虽然…但是… with a sentence | Ground a grammar card in that example |

## Milestones and acceptance

| Milestone | Evidence before moving on |
| --- | --- |
| M0 · First prototype, issue #2 | Record Xcode, SDK, and target OS. Build the Xcode project. Write, save, relaunch, and reopen an ink sample. Record simulator and physical iPad results separately. Check PKStrokeRecognizer availability and record any fallback or pending device check. |
| M1 · Local notebook | Create two pages, write, erase, undo, and reopen both offline. Verify page isolation and original ink. |
| M2 · Inline suggestion | Use the fùzé example. Verify placement, quiet timing, dismiss, edit, alternatives, accept, undo, stale result handling, and continued writing after an AI failure. |
| M3 · Cards and export | Cover every required card type. Verify source links and ambiguity, review and study approved cards, and import a representative deck into Quizlet. Check card count, delimiters, Chinese, and pinyin. |
| M4 · iPad pilot | Record recognition errors by writing type, suggestion latency and usage, card edits, and learner feedback. Review evidence before extending scope. |

For recognition, capture reference versus observed output on mixed Mandarin, pinyin, and English ink. Record recognized spans, tone errors, ink locations if available, and latency. A missing device or unsupported SDK is a pending check with an explicit next action. Advance to the next milestone only through a new or updated team-approved issue.
