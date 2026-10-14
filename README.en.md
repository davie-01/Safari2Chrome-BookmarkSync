# BookmarkSync

Keeps bookmarks in step between **Safari** and Chromium browsers — **Chrome, Edge, Brave, Vivaldi, Arc** — on one Mac. Everything happens locally: no server, no account, nothing uploaded.

[中文](README.md) · [Architecture](docs/ARCHITECTURE.md) · [Privacy](PRIVACY.md)

---

## What it does

- **Two-way sync across every endpoint.** Safari is one endpoint; every browser profile with the extension installed is another. Change a bookmark anywhere and the rest follow.
- **Per-endpoint settings:** enabled or not, and two-way / receive only / send only.
- **See changes before they happen.** A scan lists every addition, edit, deletion, conflict and re-ordering, says which endpoint changed it and where it will be written, and applies only what you tick.
- **Automatic sync** a few seconds after a change, for the safe cases. Deletions are off by default — turn them on with a per-run limit. Conflicts and large re-sorts always wait for you.
- **Folder order** is synced too, with a configurable endpoint whose order wins.
- **Careful with Safari:** a full backup before every write, a fidelity check on the whole file, an atomic replace, and a re-read afterwards. Writes work while Safari is running (verified on macOS 26).
- **English and Chinese**, following the system or set by hand.
- **Clean uninstall:** the background service, every browser's connection file, sync state, backups, logs and preferences.

> Tested on macOS 26.5 with Safari 26.5 and Chrome. Other Chromium browsers use the same extension APIs and should work, but have not been verified one by one.

## Install

Requires macOS 14 or later.

### 1. The app

Download `BookmarkSync-x.y.z.dmg` from [Releases](https://github.com/davie-01/Safari2Chrome-BookmarkSync/releases) and drag BookmarkSync into Applications.

The build is not notarised by Apple, so macOS blocks the first launch ("Apple could not verify it is free of malware"). Two ways through:

- **System Settings:** dismiss the dialog, open **System Settings → Privacy & Security**, scroll to the "BookmarkSync was blocked" line and press **Open Anyway**, then confirm.
- **One line in Terminal:**

  ```bash
  xattr -dr com.apple.quarantine /Applications/BookmarkSync.app
  ```

  That clears the download quarantine flag and the app opens normally. Add `sudo` if it complains about permissions.

> Before macOS 15 a right-click → Open was enough; Sequoia removed that shortcut, so use one of the two above.

Or build it yourself:

```bash
git clone https://github.com/davie-01/Safari2Chrome-BookmarkSync.git
cd BookmarkSync
scripts/build-app.sh        # builds, packages, installs into ~/Applications, registers the service
```

### 2. Full Disk Access

macOS protects Safari's bookmark file. Open **System Settings → Privacy & Security → Full Disk Access**, add BookmarkSync and tick it, then press *Restart the service* on the app's Access page.

(With an ad-hoc signature you have to tick it again after each rebuild.)

### 3. The browser extension

Download `bookmarksync-extension-x.y.z.zip` from the release and unzip it, or use the `extension/` directory from this repository. Then, in the browser: open `chrome://extensions`, turn on **Developer mode**, choose **Load unpacked** and pick that directory.

The extension ID is fixed (`dllnilcheahcklaiheddleegbdalbcjn`), so it survives reinstalls.

Install it once per browser, and once per profile — each profile is its own endpoint.

## Using it

The window has five tabs:

| Tab | What's there |
| --- | --- |
| Sync | Scan, review each change, apply, history |
| Endpoints | Every browser's status, on/off, and mode |
| Rules | Automatic sync, delay, deletion limit, which endpoint sets the order, writing while Safari runs |
| Access | Full Disk Access, background service, extension connection, notifications |
| Advanced | Safari bookmark file, language, storage and cleanup, reset sync state, uninstall |

The first sync merges the endpoints (identical bookmarks are paired automatically) and deletes nothing.

The menu bar icon syncs on demand and reopens the window. ⌘Q just closes the window — syncing continues — and *Quit BookmarkSync* in the menu bar icon really quits.

## Uninstall

Advanced → **Uninstall…**. It removes the login item, every browser's connection file, the sync state and backups, logs, preferences and caches, and moves the app to the Trash. **Remove the browser extension yourself** on the browser's extensions page.

Dragging the app to the Trash works too: the background service notices its bundle is gone, cleans up and stops.

## Where the data lives

| What | Where |
| --- | --- |
| Sync state, settings, backups | `~/Library/Application Support/BookmarkSync/` |
| Logs | `~/Library/Logs/BookmarkSync/` |
| Safari backups | `Backups/` in the folder above, one per write |

Backups and logs are kept for 30 days by default, and the newest 10 backups whatever their age. Both are configurable on the Advanced tab.

## Questions

**Does anything leave the Mac?** No. There is no server and no sign-in.

**What if a browser is closed?** Its changes are picked up the next time it opens; Safari can be read and written at any time. With background sync on, syncing continues with every browser closed.

**Could it delete bookmarks by mistake?** Deletions are never applied unless you tick them, or you turn on automatic deletion — which has a per-run limit and refuses to run when many bookmarks disappear at once (iCloud rebuilding them, say). Safari is fully backed up before every write.

**Can it write while Safari is open?** Yes — verified on macOS 26 / Safari 26, where written bookmarks appear immediately. You can switch it off on the Rules tab and let writes wait for Safari to quit.

**Does iCloud bookmark sync clash with it?** No: the file's fingerprint is checked immediately before the write, and the write is abandoned if anything changed in the meantime.

## Layout

```
BookmarkSync/
├── extension/                The browser extension — and the UI and sync engine the app reuses
│   ├── manifest.json         MV3 manifest; the key field pins the extension ID
│   ├── background.js         Service worker: the executor that reads and writes this
│   │                         browser's bookmarks, reports changes, relays UI requests
│   ├── agent-client.js       Native messaging client for talking to the background service
│   ├── chrome-adapter.js     chrome.bookmarks ↔ the normalised tree
│   ├── backup-order.js       Restores folder order from a Chrome bookmarks HTML export
│   ├── build-engine.mjs      Bundles engine/ into native/Resources/engine.js with esbuild
│   ├── engine/               The sync engine (plain JS; the app runs it in JavaScriptCore)
│   │   ├── coordinator.js    Scan → preview → apply → re-read → commit, settings, history
│   │   ├── multi.js          Multi-endpoint passes, cross-endpoint conflicts, state migration
│   │   ├── hub.js            The unified version tree
│   │   ├── diff.js           Three-way comparison and classification of every change
│   │   ├── plan.js           Turns choices into per-endpoint operations, verified in a simulator
│   │   ├── commit.js         Advances each baseline, only where the endpoints now agree
│   │   ├── tree.js           Tree index and the in-memory simulator
│   │   ├── util.js           URL canonicalisation, UUIDs, root constants
│   │   ├── url.js            A WHATWG URL serialiser (JavaScriptCore has no URL)
│   │   └── host.js           The engine's entry point inside the app
│   ├── ui/                   The interface, shared by the extension page and the app's Sync tab
│   │   ├── index.html/ui.css/ui.js   Diff list, per-item choices, conflicts, history, settings
│   │   ├── i18n.js           Language switching and lookups
│   │   └── en.json           Chinese source strings → English (the app reads this file too)
│   ├── icons/
│   └── test/                 56 tests: engine, multi-endpoint, URL, UI logic, fuzz and stress
├── native/                   The Swift side
│   ├── Package.swift         Three targets: SafariBookmarks, AgentCore, the app and the CLI
│   ├── Resources/            The bundled engine.js and the app icon
│   └── Sources/
│       ├── SafariBookmarks/  Safari's Bookmarks.plist: model and fidelity-preserving edits
│       ├── AgentCore/        Background service and system integration
│       │   ├── Agent.swift            Socket server, endpoint RPC, automatic sync
│       │   ├── EngineHost.swift       Runs engine.js in JavaScriptCore
│       │   ├── SafariStore.swift      Backup, atomic replace, re-read verification
│       │   ├── StateStore.swift       Sync state with optimistic concurrency
│       │   ├── NativeHost.swift       Native messaging relay
│       │   ├── Installer.swift        Login item and per-browser connection files
│       │   ├── Cleanup.swift          Backup and log statistics and retention
│       │   ├── Uninstall.swift        What to remove, removing it, residue check
│       │   └── Support.swift          Identifiers, paths, logging, JSON and socket helpers
│       ├── BookmarkSyncApp/  The SwiftUI app (the same binary is the background service)
│       └── bmsync/           CLI: install/uninstall/status/dump/apply, and the native host
├── scripts/
│   ├── build-app.sh          Build, package the .app, install it, register the service
│   ├── package.sh            dmg, extension zip and checksums
│   └── dev/                  Development helpers
├── docs/ARCHITECTURE.md
└── .github/workflows/        CI and release
```

## Development

```bash
cd extension && node --test test/*.test.js   # sync engine and UI logic
cd native && swift test                      # Safari read/write, fidelity, engine host
node extension/build-engine.mjs              # rebuild the bundle after changing extension/engine/**
scripts/build-app.sh                         # package and install
```

The engine is plain JavaScript (`extension/engine/`), running in JavaScriptCore inside the app and in Node for the tests — the same code either way. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Licence

GNU General Public License v3.0 — see [LICENSE](LICENSE).

In short: use, modify and redistribute freely, but a modified version you distribute (binaries included) has to be GPLv3 too, with its source available. Changes you keep to yourself carry no obligation.
