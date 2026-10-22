#!/usr/bin/env bash
# fm-install-ruby.sh - install CI's pinned, verified portable Ruby build.
#
# Downloads Homebrew's relocatable portable-ruby bottle for the host OS/arch,
# verifies its SHA-256 pin, unpacks it under the destination's parent
# directory, and links its ruby executable into the destination directory, so a
# self-hosted runner whose image lacks Ruby, and whose runner user cannot write
# the hosted tool cache that ruby/setup-ruby's prebuilt Rubies require, still
# runs the tests that parse YAML with Ruby. The bottle bundles its own libyaml
# and OpenSSL, so it needs no system packages. Supported platforms: linux
# amd64/x86_64, linux arm64/aarch64, darwin arm64/aarch64. Pins come from the
# release's own asset digests. Verification uses sha256sum when present,
# otherwise shasum -a 256. An unsupported OS/arch or a missing pin fails
# without downloading.
#
# Usage:
#   fm-install-ruby.sh <destination-directory>
set -eu

VERSION=3.4.5

die() {
  printf 'fm-install-ruby.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-ruby.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are the GitHub release asset digests for portable-ruby 3.4.5
# (https://github.com/Homebrew/homebrew-portable-ruby/releases/tag/3.4.5).
case "${os}-${arch}" in
  Linux-x86_64|Linux-amd64)
    ASSET="portable-ruby-${VERSION}.x86_64_linux.bottle.tar.gz"
    SHA256=5ea0e3a30feef0743da5a2924c8a71baead1b9f1d571afbd675bc556e59705f5
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET="portable-ruby-${VERSION}.arm64_linux.bottle.tar.gz"
    SHA256=58ab194fb0513e8d3f5a3b9a8658cb9909438b405308bf898508eed2b83afc7d
    ;;
  Darwin-arm64|Darwin-aarch64)
    ASSET="portable-ruby-${VERSION}.arm64_big_sur.bottle.tar.gz"
    SHA256=20fa657858e44a4b39171d6e4111f8a9716eb62a78ebbd1491d94f90bb7b830a
    ;;
  *)
    die "unsupported platform ${os}-${arch}; need linux on amd64/x86_64 or arm64/aarch64, or darwin on arm64/aarch64"
    ;;
esac
[ -n "$SHA256" ] || die "no pinned checksum for ${os}-${arch}"

URL="https://github.com/Homebrew/homebrew-portable-ruby/releases/download/${VERSION}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-ruby.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ASSET"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-ruby.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-ruby.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the portable Ruby archive"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-ruby.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ASSET" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}
mkdir -p "$DESTINATION"
DESTINATION=$(cd "$DESTINATION" && pwd -P)
PREFIX="$(dirname "$DESTINATION")/portable-ruby-${VERSION}"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
tar -xzf "$TMP/$ASSET" -C "$PREFIX" --strip-components=2
ln -sf "$PREFIX/bin/ruby" "$DESTINATION/ruby"
"$DESTINATION/ruby" -ryaml -rjson -e 'puts "ruby #{RUBY_VERSION} with yaml #{Psych::LIBYAML_VERSION}"'
