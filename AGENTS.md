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
- Never erase, reset, replace, or edit the user's saved portfolios while testing,
  building, taking screenshots, or verifying changes. Use disposable test data
  and isolated preferences/session directories. Never use the live Barista or
  Marketbar preferences domains for tests, and never launch a test app against
  the user's data. Agent-run Swift tests must set `BARISTA_TEST_MODE=1`, which
  uses in-memory preferences and blocks app/helper startup and migration.
  This is a permanent user requirement.
- Keep exactly one installed app per product: `/Applications/Marketbar.app`
  and, when wanted, `/Applications/Barista.app`. Never leave additional `.app`
  copies in the repo, Downloads, Desktop, Trash, or test directories. Build-only
  verification must compile without assembling apps; updates must replace the
  canonical installed app and clean their temporary staging directory. Identify
  bundles by bundle ID and verify the latest build before removing duplicates.
  Preserve preferences, portfolios, and the independent research service. This
  is a permanent user requirement.
- Menu-bar dropdown edits must propagate to the live menu (see latest fix
  history) — test dropdown paths, not just model logic.
- Docs in `docs/`, screenshots via `take-screenshots.sh`.
