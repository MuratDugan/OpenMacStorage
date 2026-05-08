# Contributing

Thanks for your interest. This is a small, hand-curated project — please keep
PRs focused, well-described, and incremental.

## Getting set up

1. macOS 14+, Xcode 16, Swift 6.0.
2. `./scripts/make-app.sh` to produce `OpenMacStorage.app`, or open `Package.swift`
   in Xcode and run.
3. Grant Full Disk Access on first run for realistic results.

## Adding or improving translations

The app uses standard `Localizable.strings` files, one per locale, under
`Sources/OpenMacStorage/Resources/<locale>.lproj/`.

The default/source locale is **English** — keys *are* the English text. Other
locales translate from English.

### To add a new language

1. Pick the right locale code (e.g. `it` for Italian, `ko` for Korean,
   `zh-Hant` for Traditional Chinese).
2. Create the directory and file:
   ```
   Sources/OpenMacStorage/Resources/<locale>.lproj/Localizable.strings
   ```
3. Copy the keys from `en.lproj/Localizable.strings` and translate the values.
4. Test by setting your Mac's preferred language to that locale, or edit the
   app's preferred languages via Terminal:
   ```sh
   defaults write com.muratdugan.openmacstorage AppleLanguages -array "<locale>"
   ```
5. Open a PR with screenshots of a few key screens.

### To improve an existing language

Find missing or awkward keys — if a string falls back to English in your
locale's UI, the key is missing or wrong. Edit `<locale>.lproj/Localizable.strings`
and submit a PR.

The initial seed translations were generated and lightly reviewed; native
speakers' refinements are very welcome.

### Tips

- Mac apps tend to use sentence-case ("Move to Trash") rather than title-case.
- Keep verbs imperative (button labels): "Scan", "Stop", "Cancel".
- Long descriptions can be longer in your language than English — that's fine,
  the layout adapts.
- Don't translate technical terms that appear identically in macOS itself
  (e.g. "Finder", "Dock", "Time Machine", "iCloud Drive").

## Code style

- Swift 6 strict concurrency is on. New types should be `Sendable` where
  reasonable.
- Prefer `@Observable` over `ObservableObject`.
- Match the existing terse-but-commented style. Comments explain *why*, not
  *what*.
- Run `swift build -c release` before pushing.

## Bug reports

Include:
- macOS version
- The path you were scanning when the issue happened
- A screenshot if it's UI-related
- Whether you have Full Disk Access granted

## Feature requests

Open an issue first to discuss before sending a large PR — small features tend
to compound into a sprawling app, which I want to avoid.
