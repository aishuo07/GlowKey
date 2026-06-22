#!/usr/bin/env sh
set -eu

APP_DIR="${1:-/Applications/GlowKey.app}"

if [ ! -x "$APP_DIR/Contents/MacOS/glowkey" ]; then
  echo "GlowKey CLI not found in: $APP_DIR" >&2
  echo "Usage: ./install-cli.sh /path/to/GlowKey.app" >&2
  exit 1
fi

mkdir -p "$HOME/bin"
ln -sfn "$APP_DIR/Contents/MacOS/glowkey" "$HOME/bin/glowkey"
ln -sfn "$APP_DIR/Contents/MacOS/glowkey" "$HOME/bin/lumensync"

echo "Installed CLI: $HOME/bin/glowkey"
echo "Legacy alias: $HOME/bin/lumensync"
echo "If needed, add this to your shell profile:"
echo "  export PATH=\"\$HOME/bin:\$PATH\""
