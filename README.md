# DiskScope

A native macOS app on one shared live file-index engine:

- **v1.0 — instant filename search** (a Mac answer to voidtools' *Everything*)
- **v1.1 — disk-space treemap** (a real Mac *WinDirStat*)

Both features are clients of the same hard thing: a complete, always-fresh index of
every file on disk (path + size + dates), built once via a fast scan and kept live.

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

## Roadmap

- **Phase 1** — the index engine: scanner + in-memory tree + FSEvents live patching.
- **Phase 2** — v1.0 search UI (hotkey, type-to-filter, keyboard-first).
- **Phase 3** — Full Disk Access onboarding & graceful degradation.
- **Phase 4** — v1.1 treemap (the WinDirStat win).
- **Phase 5** — persistence & polish (only if scan time demands persistence).
