# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MenuWidgets is a native Swift (SwiftPM, no Xcode project) macOS 15+ menu-bar app with five widgets: Time, Weather, Reminders, Claude usage ("agents"), and Mail (HEY + Gmail). Many widgets are ports of the Omarchy (Linux) bar's widgets, and comments and commit messages often compare against Omarchy's behavior.

## Commands

```sh
scripts/test.sh                        # unit tests (wraps `swift test`)
scripts/test.sh --filter partialConfigKeepsDefaults   # one test (args pass through to swift test)
scripts/test.sh --filter MailTests     # one test file
swift build                            # debug build
scripts/build-app.sh                   # release build → build/MenuWidgets.app (ad-hoc signed)
scripts/install.sh                     # build, copy to ~/Applications, (re)start under launchd
swift scripts/make-icon.swift Assets/AppIcon.png   # redraw the app icon
```

Use `scripts/test.sh`, not plain `swift test`: with only the Command Line Tools installed, Swift Testing's macro plugin must be loaded explicitly. Tests use Swift Testing (`@Test`, `#expect`), not XCTest.

The installed app runs as LaunchAgent `com.ianneub.menu-widgets`; its log is `~/Library/Logs/MenuWidgets.log`. Rebuilding with an ad-hoc signature makes macOS ask for Reminders permission again (a stable identity can be set in `~/.config/menu-widgets/sign-identity` or `MENU_WIDGETS_SIGN_IDENTITY`).

### Development env vars

Set when launching the binary to check UI without clicking:
- `MENU_WIDGETS_OPEN=<widget id>` opens that widget's popup at launch.
- `MENU_WIDGETS_TIME_DETAIL=<n>`, `MENU_WIDGETS_WEATHER_DETAIL=<n>`, `MENU_WIDGETS_REMINDERS_EDIT=<row>[,<preset>]` open a popup with a specific side pane/form.
- `MENU_WIDGETS_TIME_SNAPSHOT=<dir>`, `MENU_WIDGETS_SNAPSHOT=<dir>` (agents) render panels to PNGs.
- `MENU_WIDGETS_AGENTS_DEMO=1` (or `=running`) swaps in fake Claude limits, one per style.
- `MENU_WIDGETS_NO_KEYCHAIN=1` skips reading Claude Code's Keychain credentials.
- `MENU_WIDGETS_MAIL_TEST=1` posts a sample new-mail banner.

## Architecture

Two targets (see `Package.swift`):
- **`WidgetsCore`**: pure logic with no AppKit/SwiftUI: config, time zones and astronomy, weather parsing, Claude usage limits and transcript scanning, the reminders agenda, repeat rules and "when" parsing, mail diffing and Gmail/HEY parsing. Everything tested lives here; put new testable logic here and keep it `public`.
- **`MenuWidgets`**: the AppKit/SwiftUI executable. Untested; anything touching EventKit, Keychain, Core Location, processes, or the network is here.

Both use Swift 5 language mode under the Swift 6 toolchain. Source folders mirror each other per widget (`Time/`, `Weather/`, `Reminders/`, `Agents/`, `Mail/` in both targets).

### App shell (`Sources/MenuWidgets/Shell/`)
- `MenuWidget` protocol (`Widget.swift`): each widget provides an `id`, a menu-bar `label()`, a `panel(host:)` view, and optional lifecycle hooks (`popupWillOpen`, `popupDidClose`, `handleEscape`, `shutdown`). `shutdown()` must stop timers, watchers, and child processes, because a widget disabled in config is torn down live.
- `StatusPanel` owns one `NSStatusItem`, its borderless popup, and an optional side pane floating to the left of the popup for hover detail. Widgets drive this through `PanelHost` (`showSidePane`, `hideSidePane`, `close`).
- `WidgetRegistry.all` lists every widget. Status items are created in that order and placed right to left. To add a widget, add an entry there plus an `enabled` setting in config.
- `AppDelegate` subscribes to `ConfigStore.shared.$config` and creates or removes widgets as their `enabled` flags change. SIGTERM (from launchd) is routed through `NSApp.terminate` so widgets can kill child processes such as `hey watch`.

### Config
`~/.config/menu-widgets/config.json`, modeled by `WidgetsConfig` in `Sources/WidgetsCore/Config.swift`. `ConfigStore` watches both the directory and the file, and reloads live. An invalid file keeps the current settings. Each settings struct has a hand-written `init(from:)` that falls back to the default for any missing or mistyped key. **When adding a config field, add it to the struct, its `init(from:)`, and the README's Configuration section** (the README documents the full default JSON).

### Notable data sources
- **Agents**: reads Claude Code's OAuth token read-only from the Keychain item `Claude Code-credentials` (never refreshes it) to probe usage limits, and `TranscriptScanner` incrementally scans `~/.claude/projects/**/*.jsonl` (honors `CLAUDE_CONFIG_DIR`) with a persisted per-file offset cache.
- **Mail**: `MailSource` subclasses (`HeySource` runs the `hey` CLI's `watch` as a child process; `GmailSource` polls the Gmail API using OAuth refresh tokens in the Keychain). `MailModel` diffs successive reads to post or withdraw notification banners. The app runs under launchd with a short PATH, so `hey` is also looked up in mise/Homebrew/`~/.local/bin` paths.
- **Reminders**: EventKit, plus the private ReminderKit framework (`ReminderStore.swift`) only for the URL field.
- **Weather**: NWS for US locations, Open-Meteo elsewhere and as the fallback; Core Location for the Mac's location when `weather.useLocation` is on.

## Conventions

- Commit messages: an imperative, sentence-case subject with no prefix, then a body explaining the why in plain prose. User-facing strings and comments follow the same plain, concrete style.
- User-visible behavior changes generally come with a README update.
