#!/usr/bin/env bash
#
# Build the Debian package from the source tree:
#   nfc-fido-pam_<ver>-1_all.deb   (verifier + enrol tool + PAM examples)
#
# Pure assembly: does NOT install anything system-wide. Output -> dist/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VER="$(cat "$ROOT/VERSION")"
PKG="nfc-fido-pam"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

echo "==> $PKG build, version $VER"

STAGE="$BUILD/$PKG"
mkdir -p "$STAGE"

# Control metadata. (Optional files/ tree for any static payload; everything
# else is installed from src/ + pam/ below as the single source of truth.)
cp -a "$ROOT/packaging/$PKG/DEBIAN" "$STAGE/DEBIAN"
if [ -d "$ROOT/packaging/$PKG/files" ]; then
  cp -a "$ROOT/packaging/$PKG/files/." "$STAGE/"
fi

# Install the executables from src/ as the single source of truth (avoids drift
# between src/ and the package tree).
install -D -m 0755 "$ROOT/src/nfc-fido-verify" "$STAGE/usr/lib/nfc-fido/nfc-fido-verify"
install -D -m 0755 "$ROOT/src/nfc-fido-enroll" "$STAGE/usr/sbin/nfc-fido-enroll"

# Ship the PAM examples as docs.
install -D -m 0644 "$ROOT/pam/hyprlock.example" \
  "$STAGE/usr/share/doc/$PKG/examples/hyprlock.example"
if [ -f "$ROOT/pam/nfc-fido.example" ]; then
  install -D -m 0644 "$ROOT/pam/nfc-fido.example" \
    "$STAGE/usr/share/doc/$PKG/examples/nfc-fido.example"
fi

# Version-stamp control; normalise perms.
sed -i "s/@VER@/$VER/" "$STAGE/DEBIAN/control"
chmod 0755 "$STAGE/DEBIAN/postinst"
find "$STAGE" -type d -exec chmod 0755 {} +

dpkg-deb --root-owner-group --build "$STAGE" \
  "$DIST/${PKG}_${VER}-1_all.deb"

echo "==> built:"
ls -1 "$DIST"
