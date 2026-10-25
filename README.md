# MenuBarTidy

> A native macOS menu bar organizer — tuck status items away behind a separator, bring them back with a click or a hotkey.

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://github.com/cduyzh/MenuBarTidy/releases)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://github.com/cduyzh/MenuBarTidy)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Author](https://img.shields.io/badge/Author-cduyzh-blue?style=flat-square)](https://github.com/cduyzh)

**English** · [简体中文](README.zh-CN.md)

MenuBarTidy is a native menu bar organizer for macOS 14 and later — a modern alternative to Hidden Bar and Ice. It collapses the status items you rarely need into hidden partitions and reveals them with a click on the separator or a global hotkey. It keeps working on the newest macOS releases (up to macOS 26), where Control Center hosts every status item and older organizers stop working.

## Features

- **Hide and reveal** — click the separator in the menu bar (or press the global hotkey, default ⌘⌃M) to switch between collapsed and expanded. Collapsing is instant: no dragging, no flicker.
- **Three partitions** — **Always-Hidden** (off-screen in both states), **Hidden** (off-screen when collapsed, back when revealed), and **Visible** (right of the separator).
- **Partition by position** — which partition an item belongs to is decided purely by where it sits relative to the separator, interaction-compatible with Hidden Bar. Hold ⌘ and drag an item across the separator line to assign it; the system's own menu bar autosave persists the layout.
- **Layout editor** — Settings › Layout lists every item per partition with its app icon and source name; ◀▶ buttons move an item in one shot, and system items show friendly names (AirDrop, Clock, …).
- **Auto-collapse** — after revealing, clicking outside the menu bar collapses the hidden partition again; the delay is configurable from 0 (manual only) to 10 seconds, with automatic grace while the pointer stays inside the menu bar or a menu is open.
- **Global hotkey** — reveal/collapse the hidden partition from anywhere; the hotkey is recordable in settings.
- **Source attribution** — three-tier resolution names the app that owns each status item, even on macOS 26 where Control Center hosts every item window.
- **Zero-permission toggling** — hiding and revealing need no permissions at all. The Accessibility permission is required only for editor moves and source attribution.
- **Launch at login** — implemented with `SMAppService`, no third-party dependencies.
- **True menu bar app** — `LSUIElement`: no Dock icon, no main window.
- **Versioning** — the version number comes solely from the root `Info.plist`; the update history lives in `CHANGELOG.md`.
- **Diagnostic log** — one enumeration-and-resolution snapshot per launch, written to `~/Library/Logs/cduyzhMenuBar/diag.log`.

## How It Works

- **Hiding by separator expansion** — on macOS ≤ 26 the menu bar relays out around any `NSStatusItem.length`. Collapsing sets the separator's length to `max(500, min(widest display × 2, 10000))` pt, and the system's own menu bar layout pushes everything left of it out of the visible area; revealing shrinks it back to 20 pt and the items flow back in. The app only ever changes its own item's length — no event synthesis, no moving other items, no fighting the system's item position memory. The always-hidden separator stays expanded permanently, so items to its left are off-screen in both the expanded and collapsed states.
- **Partition semantics** — the on-screen order is `[always-hidden items][AH separator][hidden items][separator][arrow][gear][visible items]`. Membership is pure geometry: right of the AH separator (and left of the main separator) means Hidden, further left means Always-Hidden, right of the main separator means Visible. The menu bar layout is persisted by the system's autosave; the app itself keeps no partition assignment table.
- **Control item stacking** — live testing on macOS 26 confirmed that newly created status items land leftmost (on-screen order is the reverse of creation order), so the control items are created in the order `[gear, arrow, separator, AH separator]` to get the required layout; before collapsing, the app verifies the separator sits on the arrow's hidden side.
- **Fail-open** — if the layout hasn't been arranged, nothing is hidden. The app prefers doing nothing over hiding the wrong things.
- **Three-tier source attribution** — ① per-app `AXExtrasMenuBar` children matched horizontally against item windows (AX element rects are content areas while windows include margins, so matching tolerates ±6 pt on X and ±8 pt on width); ② per-app scoped AX hit-testing for Electron / self-drawn items that expose no extras bar (a hit inside the app's own AX tree returns the item element); ③ system-level hit-testing with frame validation to avoid false positives from a foreground menu bar. Every AX call is wrapped in a 0.3–1.2 s timeout with caching, and the source PID is remembered for as long as the window lives.
- **Editor moves only** — a synthetic ⌘-drag is used only inside the layout editor: faithful drag timing, drop verification, a failure cooldown, and a screen-edge mouseUp fallback, one shot per move.
- **Window numbers as 64-bit `Int`** — from macOS 26 window numbers can exceed 32 bits (and `NSStatusItem` window numbers encode the slot ordinal in the high bits), so they are carried as `Int` end-to-end with no `UInt32` truncation.
- **Known boundary** — macOS 27 evicts oversized separators from the menu bar (upstream Hidden Bar #360); switching to the `MenuBarClientCore` assessment-mode assertion is the recorded upgrade path. With extremely many menu bar items, the collapse/expand relayout is done by the system and individual items may land a few points off.

## Permissions

- **Toggling (hide/reveal): zero permissions.** Expanding and collapsing the separator is plain AppKit and needs no authorization at all.
- **Accessibility** is requested only for two features: moving items in the layout editor and resolving the source app of each status item.
- **Never screen-records.** The app does not capture the screen and never asks for Screen Recording permission.
- Everything runs locally on this Mac; there is no network telemetry.

## Download and Install

1. Download the latest `cduyzhMenuBar-*.dmg` from [Releases](https://github.com/cduyzh/MenuBarTidy/releases).
2. Open the DMG and drag **MenuBarTidy** into `/Applications`.
3. Launch the app. If you want editor moves and source attribution, grant Accessibility when prompted (System Settings › Privacy & Security › Accessibility).
4. Open Settings › Layout and move the items you don't want permanently visible into Hidden or Always-Hidden.
5. Click the double-arrow separator in the menu bar (or press ⌘⌃M) to reveal and collapse the hidden partition.

## Build from Source

Requires Xcode or Command Line Tools (Swift 5.9+) on macOS 14+.

```bash
git clone https://github.com/cduyzh/MenuBarTidy.git
cd MenuBarTidy
./build_app.sh          # compiles Release and bundles cduyzhMenuBar.app
```

The build produces the app bundle locally and does not auto-install; `scripts/install-local.sh` performs a verified, atomic install into `/Applications` with backup and rollback. Plain `swift build` and `swift test` also work for development.

## Version History

The current version is **0.2.0** (build 6), taken from the root `Info.plist` — the single source of truth for version and build numbers. See [CHANGELOG.md](CHANGELOG.md) for the full history.

## Privacy

Everything happens locally on your Mac. The app contains no analytics and makes no network requests of its own; the diagnostic log written once per launch to `~/Library/Logs/cduyzhMenuBar/diag.log` stays on this machine.

## License

Released under the [MIT License](LICENSE).

## Author

**cduyzh**

- GitHub: <https://github.com/cduyzh>
- Website: <https://www.cduyzh.top>
- Goal: <https://www.cduyzh.top/goal>
