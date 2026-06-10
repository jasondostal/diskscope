# DiskScope — performance & polish batch (2026-06-09)

From the full code review. Working order: Core engine → TUI + GUI in parallel.

## Core: scan engine
- [x] ERANGE-after-exact-fill fix (`getattrlistbulk` returns ERANGE, not 0, after an exact buffer fill — currently loses the tail + miscounts an error)
- [x] Per-worker reused 1 MiB attr buffer (drop the 256 KiB malloc/free per directory)
- [x] Subtree chunking in parallel workers: pop a dir, descend inline via `openat` (budget ~1k entries, depth-capped), spill the rest to the queue — kills per-dir full-path namei + most queue lock traffic
- [x] Dedup (dev,ino) check on its own cheap lock, out of the queue condvar

## Core: persistent index + FSEvents replay (the incremental-indexing hack)
- [x] `IndexStore`: serialize the flat arena (columnar binary + name blob) to ~/Library/Application Support/DiskScope/
- [x] Capture FSEvents event ID at scan start; save it with the index
- [x] `FSEventsWatcher` learns `sinceEventId` + HistoryDone/IdsWrapped/MustScanSubDirs handling
- [x] `WarmStart.load(root)`: load store → replay FSEvents since saved ID → reconcile → ready in <1s (falls back to full scan when journal can't serve us)
- [x] Both frontends: warm-start on launch, save on exit/scan-complete

## Core: index engine
- [x] Incremental aggregate: `reconcile()` computes its own byte/file/item delta (incl. per-extension bytes) and patches ancestors in O(depth) — no more full O(n) aggregate per change
- [x] `reconcileSubtree(path)` for deep FSEvents flags (tombstone + re-graft)
- [x] Search: precomputed lowercased names (kill the 1M `lowercased()` allocs per query)
- [x] Tests: incremental-vs-full aggregate equivalence; IndexStore round-trip

## Core: treemap renderer
- [x] Hole fix: dirs whose children fall below minSide render as backdrop cushions (no more background holes)
- [x] Parallelize the Phong render across row bands (~6× on P-cores)
- [x] Gamma-correct shading (shade in linear light, LUT back to sRGB)
- [x] Subtle specular term (van Wijk gloss)

## TUI
- [x] Scan progress during initial index + rescan (wire `onProgress`)
- [x] Warm-start + save-on-quit
- [x] `/` search (global, navigable results, jump-to-parent on Enter)
- [x] `s` sort toggle (size / name / modified)
- [x] Mouse support (SGR 1006): click list rows, click treemap tiles, scroll wheel
- [x] Wide-glyph (CJK/emoji) column-width handling
- [x] Self-pipe wakeup instead of self-SIGWINCH poke

## GUI
- [x] Retina-resolution cushion bitmap (render at displayScale, not points)
- [x] Re-enable live FSEvents refresh using incremental deltas (Live-Wire at last)
- [x] Incremental legend (per-ext deltas, no full rebuild)
- [x] ⌘F search field with results list → selects/reveals in tree
- [x] Double-click treemap tile → focus/zoom into that branch
- [x] Quick Look on Space for the selected node
- [x] Per-directory structure borders at all depths (subtle, depth-faded)
- [x] Spatial grid for hover hit-testing
