# DiskScope — performance & polish batch (2026-06-09)

From the full code review. Working order: Core engine → TUI + GUI in parallel.

## Core: scan engine
- [ ] ERANGE-after-exact-fill fix (`getattrlistbulk` returns ERANGE, not 0, after an exact buffer fill — currently loses the tail + miscounts an error)
- [ ] Per-worker reused 1 MiB attr buffer (drop the 256 KiB malloc/free per directory)
- [ ] Subtree chunking in parallel workers: pop a dir, descend inline via `openat` (budget ~1k entries, depth-capped), spill the rest to the queue — kills per-dir full-path namei + most queue lock traffic
- [ ] Dedup (dev,ino) check on its own cheap lock, out of the queue condvar

## Core: persistent index + FSEvents replay (the incremental-indexing hack)
- [ ] `IndexStore`: serialize the flat arena (columnar binary + name blob) to ~/Library/Application Support/DiskScope/
- [ ] Capture FSEvents event ID at scan start; save it with the index
- [ ] `FSEventsWatcher` learns `sinceEventId` + HistoryDone/IdsWrapped/MustScanSubDirs handling
- [ ] `WarmStart.load(root)`: load store → replay FSEvents since saved ID → reconcile → ready in <1s (falls back to full scan when journal can't serve us)
- [ ] Both frontends: warm-start on launch, save on exit/scan-complete

## Core: index engine
- [ ] Incremental aggregate: `reconcile()` computes its own byte/file/item delta (incl. per-extension bytes) and patches ancestors in O(depth) — no more full O(n) aggregate per change
- [ ] `reconcileSubtree(path)` for deep FSEvents flags (tombstone + re-graft)
- [ ] Search: precomputed lowercased names (kill the 1M `lowercased()` allocs per query)
- [ ] Tests: incremental-vs-full aggregate equivalence; IndexStore round-trip

## Core: treemap renderer
- [ ] Hole fix: dirs whose children fall below minSide render as backdrop cushions (no more background holes)
- [ ] Parallelize the Phong render across row bands (~6× on P-cores)
- [ ] Gamma-correct shading (shade in linear light, LUT back to sRGB)
- [ ] Subtle specular term (van Wijk gloss)

## TUI
- [ ] Scan progress during initial index + rescan (wire `onProgress`)
- [ ] Warm-start + save-on-quit
- [ ] `/` search (global, navigable results, jump-to-parent on Enter)
- [ ] `s` sort toggle (size / name / modified)
- [ ] Mouse support (SGR 1006): click list rows, click treemap tiles, scroll wheel
- [ ] Wide-glyph (CJK/emoji) column-width handling
- [ ] Self-pipe wakeup instead of self-SIGWINCH poke

## GUI
- [ ] Retina-resolution cushion bitmap (render at displayScale, not points)
- [ ] Re-enable live FSEvents refresh using incremental deltas (Live-Wire at last)
- [ ] Incremental legend (per-ext deltas, no full rebuild)
- [ ] ⌘F search field with results list → selects/reveals in tree
- [ ] Double-click treemap tile → focus/zoom into that branch
- [ ] Quick Look on Space for the selected node
- [ ] Per-directory structure borders at all depths (subtle, depth-faded)
- [ ] Spatial grid for hover hit-testing
