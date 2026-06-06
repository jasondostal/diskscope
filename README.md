# DiskScope

**A real Mac *WinDirStat*** — hit scan, and seconds later see exactly what's eating your
disk as a fast, zoomable, colored treemap. Every file a rectangle sized by bytes.

The category has DaisyDisk and GrandPerspective, but none replicates WinDirStat/WizTree's
*scary-fast whole-drive scan* — because the Windows versions read the NTFS Master File
Table directly and macOS/APFS has no MFT. So the engineering *is* the product: we build
the fast scan ourselves with `getattrlistbulk(2)` + a parallel walk.

> **Pivot note (2026-06-05):** DiskScope started as a two-app idea (instant filename search
> *and* a treemap on one engine). Mid-build we found [Cling](https://github.com/FuzzyIdeas/Cling) —
> a mature, polished, open-source native "Everything for Mac" that already fills the search
> gap well. It does **no** disk-space view, so the WinDirStat gap is wide open and that's
> where DiskScope now points. The search engine work is preserved (see `Sources` + research
> docs) for a possible later differentiated angle, but the treemap is the product.

## Status — Phase 0 (scan-speed de-risk): ✅ PASSED

Windows' Everything/WizTree are fast because they read the NTFS Master File Table
directly. macOS/APFS has no MFT, so we build the equivalent with `getattrlistbulk(2)`
(bulk directory stat) + a parallel walk.

Measured on an M5 Pro, Data volume, ~1.71M entries, warm cache:

| Scanner | Time | Rate |
|---|--:|--:|
| serial | 20.9s | 82k/s |
| parallel ×8 | **4.2s** | **410k/s** |

Findings:
- The scan is **kernel/syscall-bound**, not language-bound — stripping ~1.5M `String`
  allocations changed the time by ~2%, so a C/Rust/Go rewrite would buy nothing per-core.
- APFS metadata reads **scale across cores** (5× at 8 workers); the kernel does not
  serialize. The throughput peak at 8 workers then degrades — a thundering-herd artifact
  in our shared-queue lock, not a silicon wall. Headroom remains.

## Build & run

Requires the Swift toolchain (Command Line Tools is enough for the CLI; full Xcode is
needed for the GUI phases).

```sh
swift build -c release --product diskscope-scan
.build/release/diskscope-scan /System/Volumes/Data 8   # <path> [workers]
```

## Layout

- `Sources/DiskScopeCore/` — the engine. `BulkScanner` (serial), `ParallelScanner` (pool).
- `Sources/diskscope-scan/` — Phase 0 CLI spike harness (count + wall-clock).
- `Tests/DiskScopeCoreTests/` — fixture tests (run under full Xcode; CLI cross-checks
  against `find` in the meantime).

## Roadmap (treemap-first, post-pivot)

- ✅ **Phase 0** — scan-speed de-risk (kernel-bound; parallel 5× → 4.2s).
- ✅ **Phase 1** — index engine: scanner + in-memory tree + size aggregation + FSEvents
  live patching. All clients build on this.
- ✅ **Treemap layout** — squarified, area-proportional, recursive, tested headless.
- **Next — parallel index build + scan tuning** (P-core cap, signal-not-broadcast; see
  `docs/research/`) so a full-volume *sized* index lands in seconds.
- **Treemap UI** — SwiftUI Canvas/Metal render of the layout: zoom, color-by-type,
  click-to-drill, right-click reveal/delete. *(Needs full Xcode for the GUI bundle.)*
- **Full Disk Access** onboarding & graceful degradation.
- **Polish** — notarized DMG, app icon. Persistence only if scan-on-demand proves too slow.
- *(Deferred)* filename **search** UI — engine exists; revisit only with a Cling-beating angle.
