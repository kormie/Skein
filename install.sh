#!/bin/sh
# Skein installer — https://github.com/kormie/Skein
#
# Install the latest release:
#   curl -fsSL https://kormie.github.io/Skein/install.sh | sh
#
# Options (environment variables):
#   SKEIN_VERSION      Install a specific version, e.g. "0.1.7" (default: latest)
#   SKEIN_BIN_DIR      Install directory (default: ~/.local/bin)
#
# The script downloads the prebuilt binary for your platform from GitHub
# Releases, verifies its SHA-256 against the release's checksums.txt, and
# installs it as `skein`. No root required for the default install dir.
set -eu

REPO="kormie/Skein"
INSTALL_DIR="${SKEIN_BIN_DIR:-$HOME/.local/bin}"
VERSION="${SKEIN_VERSION:-latest}"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'skein install: %s\n' "$*" >&2
  exit 1
}

# --- platform detection -------------------------------------------------
os=$(uname -s)
case "$os" in
  Linux) os="linux" ;;
  Darwin) os="macos" ;;
  *) fail "unsupported OS '$os' — prebuilt binaries cover Linux and macOS.
See https://github.com/$REPO#option-b-build-from-source for other platforms." ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64 | amd64) arch="x86_64" ;;
  aarch64 | arm64) arch="aarch64" ;;
  *) fail "unsupported architecture '$arch' — prebuilt binaries cover x86_64 and aarch64." ;;
esac

asset="skein-$os-$arch"

if [ "$VERSION" = "latest" ]; then
  base_url="https://github.com/$REPO/releases/latest/download"
else
  base_url="https://github.com/$REPO/releases/download/v${VERSION#v}"
fi

# --- download tool ------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
else
  fail "neither curl nor wget found"
fi

# --- checksum tool ------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum "$1"; }
elif command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 "$1"; }
else
  fail "neither sha256sum nor shasum found — cannot verify the download"
fi

# --- download and verify ------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading $asset ($VERSION) ..."
fetch "$base_url/$asset" "$tmp/skein" ||
  fail "download failed: $base_url/$asset
Check https://github.com/$REPO/releases for available versions and platforms."
fetch "$base_url/checksums.txt" "$tmp/checksums.txt" ||
  fail "could not download checksums.txt for verification"

expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$tmp/checksums.txt")
[ -n "$expected" ] || fail "no checksum entry for $asset in checksums.txt"

actual=$(checksum "$tmp/skein" | awk '{ print $1 }')
[ "$actual" = "$expected" ] ||
  fail "checksum mismatch for $asset
  expected: $expected
  actual:   $actual
The download may be corrupted — please retry."

# --- install ------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
chmod +x "$tmp/skein"
mv "$tmp/skein" "$INSTALL_DIR/skein"

say "Installed: $INSTALL_DIR/skein"
env -u SKEIN_VERSION -u SKEIN_BIN_DIR "$INSTALL_DIR/skein" version 2>/dev/null || true

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    say ""
    say "NOTE: $INSTALL_DIR is not on your PATH. Add it with:"
    say "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac

say ""
say "Get started:  skein new my-agent && cd my-agent && skein test"
say "Docs:         https://kormie.github.io/Skein/"
