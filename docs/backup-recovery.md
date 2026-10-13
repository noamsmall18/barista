# Backup and recovery

Open the small **Backup & Recovery…** button at the bottom of the Marketbar
sidebar or menu-bar dropdown, or use the app menu. The compact window includes
all backup and restore options. Barista exposes the same screen in its app menu.

Automatic snapshots cover portfolios, share counts, cost basis, cash, recorded
trades, watchlists, chart history, research notes and preferences, widget
settings, layouts, and app settings. Snapshots are taken before and after
portfolio/widget/layout/research edits, before deleting a portfolio's history,
on launch, and approximately every 15 minutes while the app is running.
Unchanged settings and ordinary quote updates do not fill the backup list.

The screen selects the newest usable backup that differs from current settings.
Choose a date to preview portfolio names, position counts, cash, and other saved
content. **Restore Selected Backup…** asks before replacing the complete saved
state. It first creates a kept **Before restore — undo this restore** backup.
Select that backup to undo a restore. Restored widgets replace their previous
instances immediately, updating the menu bar and open portfolio window.

**Back Up Now** creates a kept local snapshot. **Save Backup File…** saves a
portable `.marketbarbackup` file; **Open Backup File…** validates and previews
an exported file before offering to restore it. Keep exported copies on another
drive or in your own backed-up folder to survive loss or failure of this Mac.
Local snapshots alone cannot recover a lost disk or a deleted backup directory.

Each product keeps its own recovery history in
`~/Library/Application Support/<product>/Recovery`. Backups cannot be restored
into the other product. The automatic retention policy keeps 100 recent snapshots
and the first snapshot of each day for 30 days. Manual and pre-restore backups
are not automatically removed. Damaged snapshots remain on disk and are excluded
from the restore picker; the last usable snapshot is protected from retention.

Files use atomic writes, owner-only permissions, a versioned envelope, and a
SHA-256 payload checksum. Restore validates the product, version, checksum,
portfolio structure, ledgers, profiles, research data, and chart JSON before
changing preferences. A failure to save the pre-restore backup prevents restore.
The preferences domain is replaced in one commit while keeping unrelated keys.
The independent research service and its session/authorization files are not
replaced. Mac permissions and system login registration are outside these files.

If saved settings disappear while an older backup exists, Recovery opens instead
of treating it as a fresh install. If existing data cannot be decoded, startup preserves a raw recovery copy
and opens Recovery instead of instantiating empty default portfolios. Failed and
pending quote rows offer **Retry**, which never deletes positions or trades.

All tests set `BARISTA_TEST_MODE=1`. Production recovery is disabled in tests;
explicit test stores require in-memory preferences and disposable directories.
Run the full suite with the installed Xcode toolchain:

```sh
BARISTA_TEST_MODE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --parallel
```

`RecoveryTests.swift` covers full round trips, undo, validation failures,
backup/export portability, retention, nested edits, missing chart history,
portfolio deletion, confirmation cancellation, native controls, retry actions,
and replacement of a live menu-bar widget after restore.
