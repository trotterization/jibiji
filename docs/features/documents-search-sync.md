# Documents, search, and folder sync

Jibiji uses PencilKit for pressure-sensitive handwriting and Pencil-only input by default. Finger drawing remains an explicit option. Flashcard source hashes are now computed when cards are inspected rather than on every ink callback. Actual Pencil latency, pressure, and palm rejection still need verification on an iPad with Apple Pencil.

## Reading and writing

The page toolbar has a Read/Write switch. Reading mode disables ink gestures and the canvas's editing/undo responder, while retaining pan and zoom. Returning to writing restores the same ink and undo history.

PDFs open in reading mode. Text selection, links, scrolling, search, and page navigation remain available. Switch to Write for pen, highlighter, eraser, lasso, and undo/redo. The same ink tools work on iPhone, with horizontal scrolling when the toolbar does not fit.

## PDF documents

Open **PDF Documents** on the notebook home screen and choose **Import PDF**. Files are copied into private storage; imports do not modify the source. PDFs must be unlocked and no larger than 100 MB.

Annotations are saved as separate PencilKit drawings for each page. A pause, leaving the document, or backgrounding saves pending annotations. An unreadable annotation file pauses editing of that page instead of replacing its ink. Failed saves retain a live buffer across document navigation, with retry on reopen or backgrounding.

Find in PDF searches selectable text and uses on-device Vision OCR for image-only pages or sparse text layers such as page numbers. English, Simplified Chinese, and Traditional Chinese are requested. Previous/next controls navigate to matches; recognized words are highlighted using a view overlay, which does not become a PDF annotation.

Imports prepare searchable text automatically. Opening the library also indexes older documents, with progress and a Stop Indexing control. Use **Document actions → Rebuild OCR Search Index** to rescan a document, including pages that mix a full text layer with images. Recognition can miss or misread words.

OCR runs away from the UI actor and saves completed pages incrementally in a protected local cache keyed to the source PDF's SHA-256. Searches reuse that cache after relaunch; changed sources and damaged cache pages are reindexed. Canceling stops further pages while retaining completed work. Search results are capped at 1,000, with a plus sign when the cap is reached. Library search includes recognized scan text as well as titles and native PDF text.

OCR provides search inside Jibiji; it does not rewrite the original PDF or embed a new text layer into image-only exports. The derived OCR page cache is excluded from folder sync; recognized library text travels with existing document metadata.

**Document actions → Export Annotated PDF** creates a standard PDF with the ink flattened onto the original pages. Text remains searchable and URL/page links are retained. Keep the Jibiji data to continue editing individual strokes. A renamed document keeps its original content.

## Organization and handwritten search

Existing folders, pins, page colors, and page descriptions remain available. Page Details now accepts comma-separated tags. Home search matches titles, descriptions, folders, colors, tags, and indexed handwriting.

Choose the text-recognition button next to search to update the handwriting index. Recognition runs on device using the existing language recognizer/fallback. Index text is derived data; original strokes are never replaced. Changes invalidate the old search entry immediately, including while a save is pending. Recognition can miss or misread words.

## Cloud folder sync

Open **Customize → Cloud Sync → Choose Cloud Folder**. Select the same folder through Files on each iPhone or iPad. iCloud Drive is the suggested choice. Other providers, including OneDrive installations that expose folder access, depend on their Files integration.

Sync checks approximately every ten seconds while Jibiji is active. It uploads saved changes without interrupting ink entry. Incoming edits are applied on the notebook home screen when no editor is open; they wait while a page or PDF is being edited. Provider delivery timing, offline availability, and background restrictions affect when another device receives changes. This is folder synchronization, not a guarantee of instant server delivery or background execution.

The selected folder contains `Jibiji Sync/devices` manifests, immutable SHA-256 content blobs, and **Readable PDFs**. Open `Readable PDFs/Browse.html` from a locally synced folder on Mac or PC to browse standard PDF copies. Editable notebook data is supported by Jibiji on iOS/iPadOS; this change does not create a Windows or Mac desktop editor. Home photos stay on their original device.

Each installation has a non-migrating Keychain writer identity. Records have stable document identities and vector clocks. Concurrent versions create a deterministic conflict copy, retaining both edits. File names and downloaded hashes are validated before import. Incoming file changes use a rollback journal; interrupted imports recover on the next launch or retry. Disconnecting retains both local and cloud data. Revision blobs are retained; automatic history cleanup is not implemented. Folder assignments, page titles, pins, and tags travel with pages. The notebook heading, page order, and view preferences remain local.

Sync currently materializes record data in memory. Large-library memory usage, provider hydration, and transfer latency need profiling before release.

## Validation

Tests use public, generated PDFs and synthetic ink. Unit coverage includes source preservation, annotation reopen/export, searchable text and links, rotated output sizes, stale handwriting indexes, two-replica convergence, concurrent edits, page-ID remapping, PDF/card sync, corrupt downloads, interrupted-import recovery, reconnection after reinstall, failed annotation-save retries, real image-only/mixed PDF OCR, Mandarin search, cropped/rotated match locations, source replacement, cache reuse/recovery, and cancellation.

`DocumentWorkspaceUITests` exercises real PDFKit/PencilKit views, search, annotation persistence, and reading-mode protection in disposable Debug notebooks. The generated textbook fixture is available only when both `-JIBIJIStoreName` and `-JIBIJIPDFFixture YES` are supplied in Debug.

Before release, connect two physical devices to the same iCloud folder and verify offline concurrent edits, reconnect, conflict copies, large PDF import/export, links after rotation, and Apple Pencil pressure/palm rejection. The local replica tests cannot establish a provider's upload latency or real-device gesture behavior.
