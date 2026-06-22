<p align="center">
  <img src="Assets/readme-hero.png" alt="Do Not Sleep menu bar app" width="720">
</p>

# Do Not Sleep

<!-- If the GitHub repository path changes, update MayoneJY/Do-Not-Sleep in the badge URLs below. -->
<p align="center">
  <a href="Scripts/build-app.sh"><img alt="Version" src="https://img.shields.io/badge/version-0.1.0-2f81f7?style=flat-square"></a>
  <a href="https://github.com/MayoneJY/Do-Not-Sleep/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/MayoneJY/Do-Not-Sleep/total?label=downloads&style=flat-square&color=2ea043"></a>
  <a href="Scripts/build-app.sh"><img alt="macOS" src="https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square&logo=apple&logoColor=white"></a>
  <a href="Package.swift"><img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-f05138?style=flat-square&logo=swift&logoColor=white"></a>
  <a href="Sources/do-not-sleep/Resources"><img alt="Languages" src="https://img.shields.io/badge/languages-EN%20%7C%20KO-8a63d2?style=flat-square"></a>
</p>

[한국어 README](README.ko.md)

Do Not Sleep is a macOS menu bar app that keeps your Mac awake while Codex and other coding agents are working.

**Download:** [Latest release](https://github.com/MayoneJY/Do-Not-Sleep/releases/latest)

## Quick Install

1. Download `Do.Not.Sleep-*.zip` from the [latest release](https://github.com/MayoneJY/Do-Not-Sleep/releases/latest), unzip it, and open `Do Not Sleep.app`.
2. Click the crescent icon in the menu bar and choose `Apply/refresh administrator permission`.
3. When Codex asks for hook trust, open `/hooks` in Codex and trust `Do Not Sleep 훅 등록 세션 동기화`.

After setup, Codex work automatically enables keep-awake, and the last completed session automatically releases it.

## Why Use It

- Keeps your Mac awake while Codex sessions are active.
- Tracks multiple concurrent agent sessions independently.
- Supports lid-closed keep-awake with a signed privileged helper.
- Releases sleep prevention automatically when work is done.
- Runs as a small macOS menu bar app, with no Python dependency.

## Requirements

- macOS 13 or later for the generated `.app` bundle.
- Swift Package Manager with Swift 6.2 or a compatible toolchain.
- `curl` for hook delivery.

No project-specific environment variables are required. User-facing app strings and internal command output are localized with SwiftPM resources. Included languages are English and Korean. You can override language lookup with `DO_NOT_SLEEP_LANG=<language-code>`.

## Build And Run

Build the app bundle:

```bash
./Scripts/build-app.sh
```

Open the menu bar app:

```bash
open "Do Not Sleep.app"
```

During development, running the package without arguments also starts the same menu bar app:

```bash
swift run do-not-sleep
```

The generated app bundle runs:

```text
Do Not Sleep.app/Contents/MacOS/DoNotSleep
```

`Scripts/build-app.sh` builds the release executable, copies localization resources, copies menu bar assets, and includes the helper install/uninstall scripts in the app bundle resources.

## First-Time Setup After Install

After installing the app, run this setup once:

1. Open `Do Not Sleep.app`.
2. Click the crescent icon in the menu bar and choose `Apply/refresh administrator permission`.
3. Enter your macOS administrator password. While setup is running, the menu bar icon shows a spinner.
4. If macOS says the app was blocked from modifying apps, open `System Settings > Privacy & Security > App Management`, allow Do Not Sleep, then run `Apply/refresh administrator permission` again.
5. When the Codex hook trust guide appears, click `Open Codex`.
6. In Codex, open `/hooks` and trust the `Do Not Sleep 훅 등록 세션 동기화` command hook.
7. After that, Codex work automatically enables keep-awake, and the last completed session automatically releases it.

This setup installs the privileged helper and registers Codex/Claude Code hooks. Python and separate Terminal commands are not required.

## Menu Bar App

The status item is an icon, not text. It uses a macOS template crescent glyph so the system handles light and dark menu bar contrast, with a small colored status dot over it.

- Green dot: keep-awake is active.
- Yellow dot: keep-awake is inactive.
- Red dot: a recent error exists, or administrator permission is not applied while lid-closed forced keep-awake is enabled.

The menu is intentionally small:

- Current keep-awake status
- Administrator permission status
- Manual keep-awake toggle
- Open at Login toggle
- Check for Updates
- Hook session count and cleanup actions
- Apply/refresh administrator permission
- Remove administrator permission, shown only when the helper is available
- Refresh status
- Quit

These policies are always on by default and are not menu toggles:

- Lid-closed forced keep-awake
- Stale hook session cleanup

Process-name based agent detection is not used.

Preferences are stored in:

```text
~/.do-not-sleep/preferences.json
```

Current defaults:

- Manual keep-awake: off
- Lid-closed forced keep-awake: on
- Stale hook session cleanup: on
- Stale session threshold: 600 seconds

## Agent Hooks

When the menu bar app is running, it listens locally at:

```text
http://127.0.0.1:17643/event
```

Use `Apply/refresh administrator permission` in the menu for first-time setup. The menu shows a setup-in-progress state while macOS administrator authentication and hook installation are running. After the helper is applied, the app also installs Codex and Claude Code hooks directly. Python is not required.

The app updates:

- `~/.codex/hooks.json`
- `~/.claude/settings.json`

Existing files are backed up with a `.before-do-not-sleep-YYYYMMDDHHMMSS` suffix before changes are written.

Codex requires manual trust for new command hooks. After installing hooks, the app shows a guide dialog. Click `Open Codex`, open `/hooks` in Codex, then trust the `Do Not Sleep 훅 등록 세션 동기화` command hook.

If macOS says “Do Not Sleep.app was blocked from modifying apps,” open `System Settings > Privacy & Security > App Management`, allow Do Not Sleep, then try again. The setup failure dialog includes an `Open App Management Settings` button for this.

Handled events:

- Codex: `UserPromptSubmit`, `PostToolUse`, `Stop`
- Claude Code: `SessionStart`, `SessionEnd`
- Subagents: `SubagentStart`, `SubagentStop`

`UserPromptSubmit`, `SessionStart`, and `SubagentStart` register sessions. `PostToolUse` refreshes Codex session activity. `Stop`, `SessionEnd`, and `SubagentStop` remove sessions.

Stale cleanup is a safety cleanup for missed stop events, crashed apps, and interrupted runs. It removes a session only when that session has a readable transcript path and the transcript file has not changed for the stale threshold. Sessions without transcript metadata are not removed by the automatic transcript check.

## Internal Commands

Do Not Sleep has a small command interface because the same Swift executable is used for development runs, diagnostics, and the privileged helper LaunchDaemon. Normal users should use the menu bar app and do not need these commands.

Useful during development:

```bash
swift run do-not-sleep
swift run do-not-sleep status
```

Internal helper mode is used only by the root LaunchDaemon:

```bash
do-not-sleep helper --config <path>
```

Other session commands exist for development/testing, but the recommended workflow is the menu bar app plus Codex/Claude hooks.

## Administrator Permission And Lid-Closed Keep-Awake

Normal IOKit assertions do not guarantee lid-closed operation. For lid-closed keep-awake, Do Not Sleep uses:

```bash
pmset -a disablesleep 1
```

That is a global macOS power setting, not a per-process assertion. Do Not Sleep therefore requires a privileged helper for this mode.

Apply permission once from the menu bar app:

1. Open `Do Not Sleep.app`.
2. Choose `Apply/refresh administrator permission`.
3. Complete the macOS administrator prompt.

No separate Terminal install step is required when using the app menu. For development or scripted setup, the same helper can be installed from this repository:

```bash
./Scripts/install-helper.sh
```

The helper installs:

- `/Library/PrivilegedHelperTools/local.do-not-sleep.helper`
- `/Library/LaunchDaemons/local.do-not-sleep.helper.plist`
- `/Library/Application Support/Do Not Sleep/helper.json`
- `/var/run/do-not-sleep-helper-<uid>.sock`

The LaunchDaemon runs the same Swift executable in helper mode:

```bash
/Library/PrivilegedHelperTools/local.do-not-sleep.helper helper --config "/Library/Application Support/Do Not Sleep/helper.json"
```

The helper accepts only these local Unix socket commands:

- `enable`
- `disable`
- `status`
- `sleepnow-if-lid-closed`

It runs only these system commands:

```bash
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
/usr/sbin/ioreg -r -k AppleClamshellState -d 1
/usr/bin/pmset sleepnow
```

`pmset sleepnow` is requested only after `ioreg` reports that the lid is already closed.

Remove administrator permission from the menu bar app when the helper is available, or run:

```bash
./Scripts/uninstall-helper.sh
```

If `SleepDisabled` remains enabled after a crash or forced quit, restore it manually:

```bash
sudo pmset -a disablesleep 0
```

Use lid-closed keep-awake carefully. It can increase battery drain and heat, especially if a closed laptop is left in a bag or enclosed space.

## State Files

Runtime files live under:

```text
~/.do-not-sleep/
```

Important files:

- `state.json`: hook sessions, menu app PID, assertion status, lid-closed application record
- `state.lock`: state file lock
- `preferences.json`: menu preferences
- `preferences.lock`: preferences lock
- `watch.lock`: internal watcher lock for development command mode
- `menu.lock`: menu app singleton lock
- `watch.log`: internal watcher log for development command mode

The internal `status` command also removes stale watcher/menu PID records when the recorded process is no longer alive. For each hook session, it prints the last hook update and transcript activity/path status when metadata is available.

## Verification

Build:

```bash
swift build
```

Build app bundle:

```bash
./Scripts/build-app.sh
```

Optional diagnostic status check:

```bash
swift run do-not-sleep status
```

Check macOS assertions:

```bash
pmset -g assertions | grep "Do Not Sleep"
```

Current verification status:

- Build with `swift build`: passing
- App bundle build with `./Scripts/build-app.sh`: passing
- Internal status command: checked
- Codex hook flow: tested in real Codex workflows
- Claude Code hook flow: implemented, needs broader verification
- Lid-closed release-to-sleep behavior: tested in interactive local runs, more long-duration testing still useful
- Fresh install on a separate macOS machine: not yet fully verified

## Release

Public distribution outside the Mac App Store should use a Developer ID signature and Apple notarization. Store notarization credentials in the Keychain once:

```bash
xcrun notarytool store-credentials "do-not-sleep-notary" \
  --apple-id "APPLE_ID" \
  --team-id "TEAMID" \
  --password "APP_SPECIFIC_PASSWORD"
```

Release output should be written to `dist/`. Keep local release automation out of git, for example `Scripts/release.local.sh` and `.release.local.env`. Do not commit `dist/`, Apple ID passwords, API keys, notarization profiles, or exported certificates.

## Updates

`Check for Updates...` uses the latest GitHub Release:

```text
https://github.com/MayoneJY/Do-Not-Sleep/releases
```

When a newer tag exists, the app selects an installable `.zip` or `.dmg` release asset, downloads it, quits the current app, replaces `Do Not Sleep.app`, and relaunches it.

Release asset requirements:

- The release tag should be higher than `CFBundleShortVersionString`, for example `v0.1.1`.
- The release must contain a `.zip` or `.dmg` asset.
- The package must contain `Do Not Sleep.app`.
- The current app location must be writable by the user. If the app is installed somewhere that requires administrator approval, move it to a user-writable location or install a signed release through the normal macOS flow.

Developer ID signing and notarization are still required for public distribution, but the updater code path can be built and tested before Apple Developer Program enrollment.

## Common Failure Modes

- Menu icon is not visible: check the right side of the macOS menu bar and menu bar organizers such as Hidden Bar or Bartender.
- Hook receiver is unavailable: start the menu bar app and confirm the menu shows `http://127.0.0.1:17643/event`.
- Codex hooks do not run: open `/hooks` in Codex and trust the installed command hook.
- macOS blocks app modification: allow Do Not Sleep in `Privacy & Security > App Management`, then run `Apply/refresh administrator permission` again.
- A session remains after stopping work: the stop hook may not have been delivered. If the session has transcript metadata and the transcript stops changing, default stale cleanup should remove it after about 10 minutes. Otherwise remove it from the hook session cleanup menu.
- Lid-closed forced keep-awake says administrator permission is required: apply permission from the menu or run `./Scripts/install-helper.sh`.
- `SleepDisabled` remains enabled after a crash: run `sudo pmset -a disablesleep 0`.
