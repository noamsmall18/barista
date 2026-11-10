# Testing

Everything runs through one script:

```sh
./test.sh                 # Swift unit/UI tests, then the web tests
./test.sh swift Sharpe    # only Swift tests whose name matches
./test.sh web             # research-workspace JavaScript tests
./test.sh integration     # shipped research helper; run ./build-research.sh first
./test.sh all             # everything
./test.sh --previews      # also save UI previews to .build/ui-previews
```

The script handles what used to be remembered by hand:

- **Safety.** `BARISTA_TEST_MODE=1` is always set, so tests use in-memory
  preferences and cannot start the installed app, the research helper, or a
  migration. Real portfolios are never read or written. The integration check
  is the one exception: the helper must really start, so it runs under a
  temporary bundle identity, preferences domain and session folder instead.
- **Toolchain.** XCTest ships with Xcode, not the Command Line Tools. When the
  active toolchain is the Command Line Tools, the script uses
  `/Applications/Xcode.app` automatically.
- **Output.** A passing run prints one summary line per suite. Failures print
  the failing assertions.
- **Flaky UI tests.** A few tests drive a real menu-bar popover, which macOS
  can dismiss when another app takes focus mid-run. Each failure is rerun once
  on its own: passing alone is reported as `flaky`, failing twice fails the run.
  No assertion is skipped or loosened.

## Layout

- `Tests/BaristaTests/` — XCTest and Swift Testing suites. `Support/` holds
  shared helpers, `Fixtures/` saved provider responses.
- `Tests/Web/` — Node's built-in test runner; `preview-server.cjs` serves the
  research desk with sample data (`node Tests/Web/preview-server.cjs`).
- `Tests/ResearchWorkspaceIntegration.cjs` — exercises the built helper bundle.

## UI previews

`./test.sh --previews` writes PNGs of real views built from disposable demo
data, drawn over the app's dark background. Use `UIPreview.save(view, named:)`
in a test to add one. AppKit layer-backed surfaces may not appear exactly as on
screen; use `./take-screenshots.sh` for real captures.
