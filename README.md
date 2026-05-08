# OpenMacStorage

A free, open-source disk space analyzer for macOS. Maps your filesystem,
demystifies the "System Data" bucket, and helps you reclaim space — no
subscriptions, no nags, no telemetry.

Think **WizTree-meets-CleanMyMac**, written in Swift, MIT-licensed.

## About this project (a note from the author)

I'm a MacBook user, not a professional developer. I built OpenMacStorage
because macOS's storage settings frustrated me — I'd open System Settings,
see "Other: 176 GB" with no way to investigate, and the third-party tools
that *did* answer that question all wanted a subscription or kept nagging me
to upgrade. The thing I needed didn't exist as free software, so I made it.

The Swift code and architecture were written with significant help from AI
(Claude). I drove the product decisions — what features to include, how the
UI should feel, which problems were worth solving — and the AI did most of
the actual coding under my direction. After using it on my own machine for a
while, it felt selfish not to share it. There's nothing here that should be
locked behind a paywall.

A note for fellow developers: I know there are mixed feelings in some
communities about software built by non-developers using AI assistance. I get
it, and I want to be straightforward about it. The code is here for anyone to
read, audit, or fork. If you spot bugs, security issues, or just badly
written code, please tell me — I'd much rather learn and fix it than ship
something broken. PRs that improve the code, the translations, or the
features are very welcome.

— Murat (muratkaya665@gmail.com)

## Features

- **Fast parallel scanner** using `getattrlistbulk(2)` — millions of files in
  ~60–90 seconds on a modern Mac.
- **Sparse-file aware** — uses `ATTR_FILE_ALLOCSIZE` so OrbStack/Docker disk
  images and dataless iCloud files report their *actual* on-disk size.
- **Treemap visualization** with squarified layout, drill-down, breadcrumb.
- **Folder browser** with multi-select, Quick Look (Space), keyboard
  shortcuts, and one-click move-to-Trash.
- **Search** across the scanned tree by name, size, or category.
- **Duplicate finder** — three-stage hashing (size → 64 KB head-hash → full
  SHA-1) to skip unnecessary I/O on large trees.
- **Old downloads cleaner** for `~/Downloads` and iCloud Drive.
- **App uninstaller** — finds an app's `Application Support`, `Caches`,
  `Containers`, `Preferences` etc. by name + bundle ID and removes them
  together.
- **"What grew?"** — diffs the latest two scans, highlights folders that
  grew by ≥100 MB.
- **File type stats** — totals per extension (.mp4, .nsp, .zip…).
- **System Data analyzer** — Time Machine local snapshots, Xcode DerivedData
  / iOS DeviceSupport / Simulators, Docker/OrbStack VMs, caches, sleep image.
- **One-click cleanup** for safe categories with size estimation and
  confirmation.
- **Persistent scans** — last scan is saved to disk; opens instantly next
  time.
- **Drag & drop** — drop any folder onto the window to scan it.

## Languages

Ships with translations for:

- 🇬🇧 English
- 🇹🇷 Türkçe
- 🇨🇳 简体中文 (Simplified Chinese)
- 🇪🇸 Español
- 🇧🇷 Português (Brasil)
- 🇷🇺 Русский
- 🇩🇪 Deutsch
- 🇫🇷 Français
- 🇯🇵 日本語

Translations were AI-seeded for breadth. Native-speaker refinements via PRs
are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 / Swift 6.0 toolchain to build from source
- Full Disk Access (System Settings → Privacy & Security) to scan inside
  `~/Library`, Mail, Messages, etc.

## Build & run

```sh
git clone https://github.com/muratdugan/OpenMacStorage
cd OpenMacStorage
./scripts/make-app.sh
open OpenMacStorage.app
```

Or open `Package.swift` in Xcode and run.

## How it's built

- **Scanner**: `getattrlistbulk(2)` for one syscall per directory (vs. one
  per entry with `readdir+stat`). A worker pool of `min(8, CPU count)`
  threads drains a shared queue; sibling directories are scanned in
  parallel.
- **Persistence**: Custom binary archive (`scan.bin`, ~50 MB for a million
  nodes). Raw little-endian fixed-width integers + UTF-8 strings, recursive
  pre-order. Loads in ~0.5 s.
- **UI**: SwiftUI with `@Observable` for the model, Charts framework for bar
  graphs, custom squarified treemap, AppKit bridges for Quick Look and
  trash.
- **Localization**: `Localizable.strings` per locale, English keys, falls
  back cleanly to English for any missing key.

## Privacy

OpenMacStorage runs entirely on your Mac. It does not phone home, send
analytics, or upload any data anywhere. The only network access is whatever
macOS itself does when you open files in Finder via the app's "Show in
Finder" buttons.

## Roadmap

- [ ] App icon + signed/notarized DMG
- [ ] External volume scanning (`/Volumes/*`)
- [ ] Optional iCloud "evict local copy" action for cloud-only files
- [ ] Pluralization via `.stringsdict` for nicer count display
- [ ] RTL UI polish for Arabic/Hebrew

## Disclaimer

OpenMacStorage performs destructive operations (moving files to the Trash,
emptying caches, deleting Xcode DerivedData and APFS snapshots, removing app
support files). The app asks for confirmation before each destructive action,
keeps a confirm-then-trash flow rather than direct deletion where possible,
and skips system-critical paths by default — but the responsibility for what
gets deleted is **yours**.

**Before using cleanup features, please make sure you have a recent backup
(Time Machine or equivalent).**

By using this app you accept:

- The software is provided **"as is"**, without warranty of any kind (see
  [LICENSE](LICENSE)).
- The author is **not liable** for any data loss, broken applications, or
  system issues that may result from using this app.
- This software was built with AI assistance by a non-professional developer.
  The source code is open for anyone to read or audit.

The same disclaimer is shown in the app on first launch and accessible
anytime via **Help → Disclaimer & Liability…**.

## License

[MIT](LICENSE) — do whatever you want with it, no warranty.
