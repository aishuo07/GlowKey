# GlowKey

GlowKey is a zero-config macOS display comfort utility.

Product promise:

> Your external display brightness is controllable from the keyboard without breaking native Mac brightness behavior.

The app should use real hardware brightness when possible and fall back to smooth software dimming when hardware control is blocked. Users should not need to understand DDC/CI, gamma tables, VCP codes, docks, or DisplayLink.

## Current Status

GlowKey currently includes:

- A menu-bar app with one slider per display.
- Native MacBook brightness control without hijacking F1/F2.
- External display control through DDC/CI when available.
- Automatic software dimming fallback when hardware control is blocked.
- Per-display brightness state, reconnect restore, and optional external-display sync.
- Cursor-based external display shortcuts: `fn + F1` and `fn + F2`.
- Fallback external display shortcuts: `command + option + -` and `command + option + =`.
- A reusable Swift core plus CLI.

Advanced hardware details stay in debug CLI commands instead of the normal UI.

## Install

For normal users:

1. Download `GlowKey-dev-macos.zip` from GitHub Releases.
2. Unzip it.
3. Move `GlowKey.app` to `/Applications`.
4. Right-click `GlowKey.app`, choose `Open`, then confirm `Open`.

GlowKey bootstraps itself on first launch: menu bar, background reconnect restore, shortcuts, and `~/bin/glowkey`.

Homebrew:

```sh
brew tap aishuo07/glowkey
brew trust aishuo07/glowkey
brew install --cask --no-quarantine glowkey
open /Applications/GlowKey.app
```

Homebrew 6 requires `brew trust` for third-party taps. `--no-quarantine` is required until GlowKey is Apple-notarized; otherwise macOS can show a misleading “damaged” warning for the unsigned app.

Shortcuts:

- `fn + F1` decreases the external display under the mouse cursor.
- `fn + F2` increases the external display under the mouse cursor.
- `command + option + -` and `command + option + =` remain available as fallback shortcuts.
- Plain Mac brightness keys keep controlling the built-in display normally.

From this checkout:

```sh
swift build
./bin/glowkey install
```

Install creates:

- `~/Applications/GlowKey.app`
- `~/bin/glowkey`
- A user LaunchAgent for reconnect restore/background mode
- Menu-bar and shortcut helpers

Uninstall:

```sh
~/bin/glowkey uninstall
```

## Release Package

Create a distributable macOS zip:

```sh
scripts/package-release.sh dev
```

The artifact is written to:

```sh
dist/GlowKey-dev-macos.zip
```

The zip contains `GlowKey.app`, `install-cli.sh`, license files, and a short install README.

Maintainer release steps, GitHub Release text, and Homebrew tap templates are documented in [docs/RELEASE.md](docs/RELEASE.md).

## Development

```sh
swift build
sh scripts/smoke-test.sh
./bin/glowkey displays
./bin/glowkey doctor
./bin/glowkey status
./bin/glowkey status --json
./bin/glowkey hotkeys start
./bin/glowkey hotkeys start 5 external --down cmd+opt+- --up cmd+opt+plus
./bin/glowkey hotkeys status
./bin/glowkey hotkeys stop
./bin/glowkey set 70
./bin/glowkey set dell 60
./bin/glowkey set "DELL P3223QE" 60
./bin/glowkey sync on
./bin/glowkey sync off
./bin/glowkey down
./bin/glowkey up 5
./bin/glowkey reset
```

Run these commands from the normal macOS Terminal app, not a remote or automation shell, so macOS exposes the active display session.

## Principles

- No setup for normal users.
- Always do something when brightness changes.
- Prefer real hardware brightness.
- Fall back quietly when hardware control is blocked.
- Show simple status: `Real brightness`, `Software dimming`, or `Limited control`.
- Keep advanced diagnostics available, but out of the main flow.
