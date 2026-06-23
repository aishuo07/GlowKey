# Releasing GlowKey

This guide covers the current unsigned release flow: GitHub Releases first, then an optional Homebrew tap for terminal users.

## Current Limitation

GlowKey is not signed or notarized yet. Zip users should right-click `GlowKey.app` and choose `Open` on first launch.

The Homebrew cask currently clears Homebrew quarantine after install to avoid the misleading unsigned-app “damaged” warning. This is an alpha distribution workaround, not a replacement for proper Apple signing and notarization.

## 1. Prepare A GitHub Repository

Create a repository named `glowkey`.

```sh
cd /Users/aikanodi/Documents/LumenSync
git init
git add .
git commit -m "Initial GlowKey release"
git branch -M main
git remote add origin git@github.com:YOUR_GITHUB_USERNAME/glowkey.git
git push -u origin main
```

If GitHub created the repo with a README already, pull first:

```sh
git pull origin main --allow-unrelated-histories
```

## 2. Build The Zip

Use a version tag. Example:

```sh
scripts/package-release.sh v0.1.0
```

Output:

```text
dist/GlowKey-v0.1.0-macos.zip
```

Smoke test before uploading:

```sh
swift build
sh scripts/smoke-test.sh
unzip -l dist/GlowKey-v0.1.0-macos.zip
```

## 3. Create A Git Tag

```sh
git tag v0.1.0
git push origin v0.1.0
```

## 4. Create GitHub Release

Open:

```text
https://github.com/YOUR_GITHUB_USERNAME/glowkey/releases/new
```

Use:

```text
Tag: v0.1.0
Title: GlowKey v0.1.0
Attach: dist/GlowKey-v0.1.0-macos.zip
```

Release notes:

```md
# GlowKey v0.1.0

GlowKey makes external display brightness feel native on macOS.

## Install

1. Download `GlowKey-v0.1.0-macos.zip`.
2. Unzip it.
3. Move `GlowKey.app` to `/Applications`.
4. Right-click `GlowKey.app`, choose `Open`, then confirm `Open`.

GlowKey installs its menu bar, background reconnect restore, shortcuts, and CLI automatically.

## Shortcuts

- `fn + F1` decreases the external display under the mouse cursor.
- `fn + F2` increases the external display under the mouse cursor.
- `cmd + option + -` and `cmd + option + =` remain available as fallback shortcuts.

Mac brightness keys keep controlling the MacBook display normally.

## Optional CLI

```sh
~/bin/glowkey status
~/bin/glowkey set dell 60
~/bin/glowkey uninstall
```

## Note

This is an early unsigned build. macOS requires right-click > Open on first launch.
```

## 5. Homebrew Cask Option

Create another repo:

```text
homebrew-glowkey
```

Homebrew tap repos are conventionally named `homebrew-<tap>`.

Clone it:

```sh
git clone git@github.com:YOUR_GITHUB_USERNAME/homebrew-glowkey.git
cd homebrew-glowkey
mkdir -p Casks
```

Copy `packaging/homebrew/glowkey.rb` from this repo to:

```text
Casks/glowkey.rb
```

Update these placeholders:

```text
YOUR_GITHUB_USERNAME
VERSION
SHA256
```

Use `VERSION` without the leading `v`. Example:

```ruby
version "0.1.0"
```

Compute SHA:

```sh
shasum -a 256 /Users/aikanodi/Documents/LumenSync/dist/GlowKey-v0.1.0-macos.zip
```

Commit and push:

```sh
git add Casks/glowkey.rb
git commit -m "Add GlowKey cask"
git push
```

User install:

```sh
brew tap YOUR_GITHUB_USERNAME/glowkey
brew install --cask glowkey
open /Applications/GlowKey.app
```

If Homebrew refuses to load the tap, users can trust it once and retry:

```sh
brew trust --tap YOUR_GITHUB_USERNAME/glowkey
brew install --cask glowkey
```

Some Homebrew 6 setups require explicit trust for third-party taps. Without trust, users may see:

```text
Refusing to load cask ... from untrusted tap
```

Until GlowKey is Apple-notarized, the Homebrew cask should clear quarantine in `postflight`. Without that, macOS may show a misleading “damaged” warning for the unsigned app.

Zip users may still need:

```text
Right-click GlowKey.app -> Open -> Open
```

## 6. Homebrew Formula Option

The cask is better for normal users. A formula can build the CLI from source, but it is more developer-focused and requires Swift tooling.

Use `packaging/homebrew/glowkey-formula.rb` as a starting point only if you want:

```sh
brew install glowkey
glowkey status
```

This will not install the menu-bar app UX by itself unless we add a more advanced formula flow later.

## 7. Later: Signed Release

When you have an Apple Developer Program account, replace this unsigned flow with:

```text
codesign
notarytool submit
stapler staple
final zip
```

That removes the right-click first-launch requirement.
