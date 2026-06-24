# GlowKey

Zero-config brightness control for Mac external displays.

Website: [aishuo07.github.io/GlowKey](https://aishuo07.github.io/GlowKey/)

GlowKey keeps the normal Mac brightness keys for the built-in display, then adds simple external-display control from the menu bar, keyboard shortcuts, and CLI.

## What It Does

- Shows a compact menu-bar app with one brightness slider per display.
- Controls external monitors with real hardware brightness when the display supports it.
- Falls back to smooth software dimming when hardware control is blocked.
- Remembers brightness per display and reapplies it after reconnects.
- Supports cursor-based shortcuts for the external display your mouse is currently on.
- Keeps technical details out of the normal UI.

Plain F1/F2 keep controlling the MacBook display. GlowKey shortcuts control external displays.

## Install

### Homebrew

```sh
brew tap aishuo07/glowkey
brew install --cask glowkey
open /Applications/GlowKey.app
```

If Homebrew refuses to load the third-party tap, trust it once and retry:

```sh
brew trust --tap aishuo07/glowkey
brew install --cask glowkey
```

GlowKey is currently unsigned and not notarized. The Homebrew cask clears the Homebrew quarantine flag after install to avoid macOS showing a misleading “damaged” warning. If macOS still blocks launch, use the troubleshooting step below.

To upgrade:

```sh
brew update
brew upgrade --cask glowkey
```

To uninstall:

```sh
brew uninstall --cask glowkey
```

### Zip

1. Download the latest `GlowKey-v*-macos.zip` from [GitHub Releases](https://github.com/aishuo07/GlowKey/releases).
2. Unzip it.
3. Move `GlowKey.app` to `/Applications`.
4. Right-click `GlowKey.app`, choose `Open`, then confirm `Open`.

Right-click open is needed until GlowKey is signed and notarized with an Apple Developer account.

Optional CLI-only setup from the zip:

```sh
/Applications/GlowKey.app/Contents/MacOS/glowkey install
```

## First Launch

Open `GlowKey.app`. First launch sets up:

- The menu-bar app.
- The reconnect/background restore helper.
- The external-display shortcut helper.
- The `glowkey` CLI in `~/bin/glowkey`.

If shortcuts do not work, macOS may require Accessibility permission. Open:

```text
System Settings -> Privacy & Security -> Accessibility
```

Then allow `GlowKey`.

## Usage

### Menu Bar

Click the GlowKey icon in the macOS menu bar.

You can:

- Drag the global/external display sliders.
- Control each display independently.
- Open the shortcuts panel.
- Quit the menu-bar app.

GlowKey does not show DDC, gamma, VCP, or hardware debug wording in the normal UI. It just applies the best available method.

### Keyboard Shortcuts

Default shortcuts:

```text
fn + F1    decrease the external display under the mouse cursor
fn + F2    increase the external display under the mouse cursor
```

Fallback shortcuts:

```text
command + option + -
command + option + =
```

The fallback shortcuts control external displays when `fn + F1/F2` are not convenient.

### CLI

After install:

```sh
~/bin/glowkey status
~/bin/glowkey displays
~/bin/glowkey set 70
~/bin/glowkey set dell 60
~/bin/glowkey set "DELL P3223QE" 60
~/bin/glowkey up
~/bin/glowkey down
~/bin/glowkey sync on
~/bin/glowkey sync off
~/bin/glowkey reset
```

Run CLI commands from the normal macOS Terminal app, not a remote shell, so macOS exposes the active display session.

## Troubleshooting

### App Says It Is Damaged

If installed with Homebrew, upgrade to the latest cask first:

```sh
brew update
brew upgrade --cask glowkey
```

If macOS still blocks it:

```sh
find /Applications/GlowKey.app -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true
open /Applications/GlowKey.app
```

Only run this if you downloaded GlowKey from the official GitHub release or installed it from the official Homebrew tap.

### Shortcuts Do Not Work

Check the helper:

```sh
~/bin/glowkey hotkeys status
~/bin/glowkey hotkeys start
```

Then allow GlowKey in:

```text
System Settings -> Privacy & Security -> Accessibility
```

### Brightness Does Not Go Low Enough

Some monitors clamp their real hardware backlight range. GlowKey handles this by keeping hardware brightness at the monitor’s floor and adding software dimming below that point.

### Hardware Brightness Is Not Available

GlowKey will still dim the display using fallback dimming. For better hardware compatibility, direct USB-C or DisplayPort connections usually work better than HDMI adapters, docks, or DisplayLink paths.

### Check Current State

```sh
~/bin/glowkey status
~/bin/glowkey doctor
```

For debug output:

```sh
~/bin/glowkey status --debug
~/bin/glowkey debug ddc-probe
~/bin/glowkey debug hardware-probe
```

## Development

Build from source:

```sh
swift build
sh scripts/smoke-test.sh
./bin/glowkey install
```

Useful development commands:

```sh
./bin/glowkey displays
./bin/glowkey doctor
./bin/glowkey status --json
./bin/glowkey menubar start
./bin/glowkey menubar stop
./bin/glowkey daemon status
./bin/glowkey hotkeys start
./bin/glowkey hotkeys start 5 external --down cmd+opt+- --up cmd+opt+plus
./bin/glowkey hotkeys stop
```

Local install creates:

- `~/Applications/GlowKey.app`
- `~/bin/glowkey`
- `~/bin/lumensync` as a legacy compatibility symlink
- A user LaunchAgent for reconnect/background restore
- Menu-bar and shortcut helpers

Uninstall local install:

```sh
~/bin/glowkey uninstall
```

## Release

Create a release zip:

```sh
scripts/package-release.sh v0.1.3
```

The artifact is written to:

```sh
dist/GlowKey-v0.1.3-macos.zip
```

Maintainer release steps and Homebrew tap details are documented in [docs/RELEASE.md](docs/RELEASE.md).

## Project Principles

- Normal users should not need to know what DDC/CI, gamma, VCP, or DisplayLink means.
- If real hardware brightness works, use it.
- If hardware brightness is blocked, still make brightness visibly change.
- Keep MacBook brightness behavior native.
- Keep advanced diagnostics in the CLI, not the main UI.
