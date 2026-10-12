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

The installed app runs as LaunchAgent `com.ianneub.menu-widgets`; its log is `~/Library/Logs/MenuWidgets.log`. Rebuilding with an ad-hoc signature makes macOS ask for Reminders and Calendars permission again (a stable identity can be set in `~/.config/menu-widgets/sign-identity` or `MENU_WIDGETS_SIGN_IDENTITY`).

### Development env vars

Set these when launching the binary to check UI without clicking. Stop the installed copy first (`launchctl bootout gui/$(id -u)/com.ianneub.menu-widgets`), or every status item shows twice, and start it again afterwards (`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ianneub.menu-widgets.plist`). The unbundled `.build/debug/MenuWidgets` crashes at launch while Mail is enabled, because notifications need an app bundle, so either turn `mail.enabled` off for the run or launch `build/MenuWidgets.app/Contents/MacOS/MenuWidgets` (a release build, so without the debug-only `MENU_WIDGETS_SNAPSHOT`).
- `MENU_WIDGETS_OPEN=<widget id>` opens that widget's popup at launch.
- `MENU_WIDGETS_TIME_DETAIL=<n>` (`-1` local time, `-3` moon phases, `0…` zones), `MENU_WIDGETS_WEATHER_DETAIL=<n>` (day row), `MENU_WIDGETS_REMINDERS_EDIT=<row>[,<preset>]` open a popup with a specific side pane/form.
- `MENU_WIDGETS_TIME_SNAPSHOT=<dir>` renders the time panel and panes to PNGs (light and dark) and quits. `MENU_WIDGETS_SNAPSHOT=<dir>` (debug builds only) writes the agents panel and label to PNGs, in the current appearance, after every refresh, and the app keeps running.
- `MENU_WIDGETS_CALENDAR_DEMO=1` fills the time popup's month calendar with made-up events instead of reading EventKit.
- `MENU_WIDGETS_AGENTS_DEMO=1` (or `=running`) swaps in fake Claude limits, one per style.
- `MENU_WIDGETS_NO_KEYCHAIN=1` skips reading Claude Code's Keychain credentials.
- `MENU_WIDGETS_MAIL_TEST=1` posts a sample new-mail banner.

## Architecture

Two targets (see `Package.swift`):
- **`WidgetsCore`**: logic with no AppKit/SwiftUI: config, hotkey parsing (`KeyCombo`), time zones and astronomy, the month calendar's event layout, weather parsing, Claude usage limits and transcript scanning, the reminders agenda, repeat rules and "when" parsing, mail diffing and Gmail/HEY parsing. Everything tested lives here; put new testable logic here and keep it `public`. Plain file I/O is fine here (config, the transcript scan and its cache). One exception to the split below: `ClaudeUsageCollector` (Agents) reads Claude Code's credentials (a file, or the Keychain through `/usr/bin/security`) and calls the usage endpoint itself.
- **`MenuWidgets`**: the AppKit/SwiftUI executable. Untested; everything else touching EventKit, Keychain, Core Location, child processes, or the network is here.

To run a child process and wait for it, use `Process.runSignalingExit()` (`Sources/WidgetsCore/ProcessExit.swift`) and wait on the semaphore it returns. Don't use `waitUntilExit()`: on a background thread it can miss the exit and block forever, which once stopped the HEY list from updating.

Both use Swift 5 language mode under the Swift 6 toolchain. Source folders mirror each other per widget (`Time/`, `Weather/`, `Reminders/`, `Agents/`, `Mail/` in both targets).

### App shell (`Sources/MenuWidgets/Shell/`)
- `MenuWidget` protocol (`Widget.swift`): each widget provides an `id`, a menu-bar `label()`, a `panel(host:)` view, and optional lifecycle hooks (`popupWillOpen`, `popupDidClose`, `handleEscape`, `shutdown`). `shutdown()` must stop timers, watchers, and child processes, because a widget disabled in config is torn down live.
- `StatusPanel` owns one `NSStatusItem`, its borderless popup, and an optional side pane floating to the left of the popup for hover detail. Widgets drive this through `PanelHost` (`showSidePane`, `hideSidePane`, `close`).
- `WidgetRegistry.all` lists every widget. Status items are created in that order and placed right to left. To add a widget, add an entry there plus an `enabled` setting in config.
- `AppDelegate` subscribes to `ConfigStore.shared.$config` and creates or removes widgets as their `enabled` flags change. It also owns `HotkeyCenter`, which registers the config's `hotkeys` through Carbon's RegisterEventHotKey (no permission needed) and runs the command. A hotkey with no `apps` is always registered; one with `apps` is registered only while one of those apps is frontmost, so in other apps the key works as usual. SIGTERM (from launchd) is routed through `NSApp.terminate` so widgets can kill child processes such as `hey watch`. It also installs a hidden Edit menu, without which ⌘C/⌘V/⌘Z don't reach text fields in an accessory app's popups.

### Config
`~/.config/menu-widgets/config.json`, modeled by `WidgetsConfig` in `Sources/WidgetsCore/Config.swift`. `ConfigStore` watches both the directory and the file, and reloads live. On a live reload, an invalid file keeps the current settings. At launch, an invalid file means all defaults, and a later `ConfigStore.update` saves them over it. `ConfigStore.update` writes the whole in-memory config back (pretty-printed, sorted keys, defaults filled in); the weather location search uses it. Each settings struct has a hand-written `init(from:)` that falls back to the default for any missing or mistyped key. Array elements are stricter: a `Hotkey` needs `key` and `command` (a bad one is dropped alone, through `Lenient`), and a `Zone` without `tz` sends the whole `zones` list back to the defaults. `GmailAccount` has no `init(from:)` at all: it uses synthesized Codable, and the `gmail` array decodes all or nothing, so a field added there must be optional, or every existing account is silently dropped (and `ConfigStore.update` later saves the empty list). **When adding a config field, add it to the struct, its `init(from:)`, and the README's Configuration section** (the README documents the full default JSON).

### Notable data sources
- **Agents**: reads Claude Code's OAuth token read-only (never refreshes it) to probe usage limits: from `$CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude`) if present, else the Keychain item `Claude Code-credentials` through `/usr/bin/security`, which needs no prompt. `TranscriptScanner` incrementally scans `~/.claude/projects/**/*.jsonl` (honors `CLAUDE_CONFIG_DIR`) with a persisted per-file offset cache.
- **Mail**: `MailSource` subclasses (`HeySource` runs the `hey` CLI's `watch` as a child process; `GmailSource` polls the Gmail API with the `gmail.metadata` scope, keeping refresh tokens in the Keychain under `com.ianneub.menu-widgets.gmail-token`). Keychain access goes through `/usr/bin/security`, not SecItem, so rebuilt or re-signed apps don't prompt. `MailModel` diffs successive reads to post or withdraw notification banners. The app runs under launchd with a short PATH, so `hey` is also looked up in mise/Homebrew/`~/.local/bin` paths.
- **Time**: the month calendar reads events through EventKit (`TimeCalendarModel`), asking for access the first time the popup opens.
- **Reminders**: EventKit, plus the private ReminderKit framework (`ReminderStore.swift`) only for the URL field.
- **Weather**: Open-Meteo always (current conditions, and days past NWS's seven), plus NWS for US forecasts; Core Location for the Mac's location when `weather.useLocation` is on.

## Conventions

- Commit messages: an imperative, sentence-case subject with no prefix, then a body explaining the why in plain prose. User-facing strings and comments follow the same plain, concrete style.
- User-visible behavior changes generally come with a README update.
