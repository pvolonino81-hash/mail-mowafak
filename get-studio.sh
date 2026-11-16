#!/usr/bin/env bash
# MAIL MOWAFAK - Studio downloader (macOS / Linux)
# Downloads the bundle, verifies its SHA-256 and extracts it.
set -euo pipefail

BASE="https://z4ln662j87l6x.space.mcode.io"
ASSET="MailRotatorStudio-Portable.zip"
SHA="e0cc3b00257baaded895549f4a0372edb274944d0712b98c58720c6037eb99bb"
DEST="${1:-$PWD/MailRotatorStudio}"

mkdir -p "$DEST"
URL="$BASE/$ASSET"
echo "Downloading $URL"
curl -fL --progress-bar -o "$DEST/$ASSET" "$URL"

if command -v shasum >/dev/null 2>&1; then
  GOT="$(shasum -a 256 "$DEST/$ASSET" | awk '{print $1}')"
else
  GOT="$(sha256sum "$DEST/$ASSET" | awk '{print $1}')"
fi

if [ "$GOT" != "$SHA" ]; then
  echo "Checksum mismatch. Expected $SHA, got $GOT" >&2
  exit 1
fi

echo ""
echo "Saved    : $DEST/$ASSET"
echo "SHA-256 : $GOT   (verified)"
echo ""
echo "Unzip it, then run Start-Studio.cmd (Windows)."
