# Barista / Marketbar — Agent Rules

Native macOS menu-bar apps (AppKit, Swift 5.9, macOS 13+, XcodeGen via
project.yml). Zero third-party dependencies — keep it that way.

- Marketbar (market terminal) and Barista (52-widget platform) share this
  codebase and ship from this repo. They install side by side with separate
  settings; Marketbar imports Barista data once on first launch.
- Build: `./build-app.sh`. Regenerate Xcode project from `project.yml`
  (XcodeGen) instead of hand-editing `.xcodeproj`.
- Tests live in `Tests/` — run them before and after behavior changes.
  Never weaken an assertion to make it pass.
- Menu-bar dropdown edits must propagate to the live menu (see latest fix
  history) — test dropdown paths, not just model logic.
- Docs in `docs/`, screenshots via `take-screenshots.sh`.
