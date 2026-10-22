#!/usr/bin/env bash
# fm-install-jq.sh - install CI's pinned, verified jq build.
#
# Downloads the official GitHub release binary for the host OS/arch, verifies
# its SHA-256 pin, and installs it into the destination directory as jq, so a
# self-hosted runner whose image lacks jq still runs the CI jobs that need it.
# Supported platforms: linux amd64/x86_64, linux arm64/aarch64, darwin
# amd64/x86_64, darwin arm64/aarch64. Pins come from the release's own
# sha256sum.txt asset. Verification uses sha256sum when present, otherwise
# shasum -a 256. An unsupported OS/arch or a missing pin fails without
# downloading.
#
# Usage:
#   fm-install-jq.sh <destination-directory>
set -eu

VERSION=1.7.1

die() {
  printf 'fm-install-jq.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-jq.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are from sha256sum.txt of jq 1.7.1
# (https://github.com/jqlang/jq/releases/tag/jq-1.7.1).
case "${os}-${arch}" in
  Linux-x86_64|Linux-amd64)
    ASSET=jq-linux-amd64
    SHA256=5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=jq-linux-arm64
    SHA256=4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5
    ;;
  Darwin-x86_64|Darwin-amd64)
    ASSET=jq-macos-amd64
    SHA256=4155822bbf5ea90f5c79cf254665975eb4274d426d0709770c21774de5407443
    ;;
  Darwin-arm64|Darwin-aarch64)
    ASSET=jq-macos-arm64
    SHA256=0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70fa04aea8a8362e8a
    ;;
  *)
    die "unsupported platform ${os}-${arch}; need linux or darwin on amd64/x86_64 or arm64/aarch64"
    ;;
esac
[ -n "$SHA256" ] || die "no pinned checksum for ${os}-${arch}"

URL="https://github.com/jqlang/jq/releases/download/jq-${VERSION}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-jq.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ASSET"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-jq.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-jq.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the jq binary"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-jq.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ASSET" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/$ASSET" "$DESTINATION/jq"
"$DESTINATION/jq" --version
