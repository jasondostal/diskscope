# DiskScope

**A native macOS WinDirStat** — hit scan, and seconds later see exactly what's eating your
disk as a fast, live, cushioned **treemap** next to a dense, sortable directory tree.

![DiskScope](readme.png)

DiskScope renders disk usage as a *squarified treemap*: every file becomes a rectangle sized
by the bytes it eats, packed to stay near-square and readable, and each rectangle is drawn as
a 3D "cushion" with per-pixel Phong lighting written straight into a raw RGBA bitmap (no
system 2D-drawing APIs), then tinted by file type through a perceptually-uniform **OKLCH**
color palette. The scan itself is a parallel `getattrlistbulk(2)` walk, so a whole disk
indexes in seconds.

## Features

- **Cushioned treemap** — squarified, area-proportional, van Wijk cushion shading, colored by
  file category in OKLCH.
- **Dense directory tree** — name, %-of-parent bar, file count, size, and last-modified
  columns; click-to-reveal in the treemap and back.
- **File-type legend** — per-extension breakdown; click a type to isolate its tiles on the map.
- **Selection inspector** — size, share of disk/parent, file & item counts, modified/created.
- **Themes** — curated OKLCH palettes (Spectrum, Dracula, Catppuccin, Nord, Solarized,
  Synthwave, Gruvbox, Cairn) plus a **Custom** theme with live sliders.
- **Real file actions** — Reveal in Finder, Open, Move to Trash (the index updates in place).
- **Full Disk Access** onboarding so protected folders get counted.
- **A full terminal UI** — the same engine, rendered as a navigable cushioned treemap right in
  your terminal (plus SVG/PNG and benchmark CLI modes).

## Install

**Homebrew (recommended):**

```sh
brew install --cask jasondostal/tap/diskscope
```

**Or grab the DMG** from the [latest release](https://github.com/jasondostal/diskscope/releases/latest).
Direct downloads are ad-hoc signed (not notarized), so macOS will flag it as from an
unidentified developer — right-click the app → **Open** the first time (or **Open Anyway** in
System Settings → Privacy & Security). Homebrew installs handle this for you.

Requires **macOS 14+**. It is intentionally not sandboxed — a whole-disk indexer needs to read
the whole disk.

## Terminal UI

`diskscope --tui <path>` is a fully interactive treemap in your terminal — same scan, same
cushions, drilling around with the keyboard. Needs a **truecolor** terminal (iTerm2, Ghostty,
kitty, WezTerm).

![DiskScope TUI](tui.png)

```sh
diskscope --tui ~          # interactive terminal UI
diskscope --treemap <path> # render a treemap SVG
diskscope --term <path>    # static cushioned treemap, printed once
diskscope <path> [workers] # scan benchmark
```

(Installed via Homebrew the CLI is on your PATH as `diskscope`; from source the product is
`diskscope-scan`.)

## Build from source

Requires the Swift toolchain (full Xcode for the GUI; Command Line Tools is enough for the CLI).

```sh
swift build --product DiskScopeApp && .build/debug/DiskScopeApp   # or: make run
make app        # build dist/DiskScope.app
make dmg        # + a distributable DMG
swift test
```

## License

[MIT](LICENSE) © Jason Dostal
