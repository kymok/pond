#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Pond"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
HELPER_PATH="$APP_DIR/Contents/Library/Helpers/taskpond"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$APP_NAME"
NOTARY_PROFILE="PondNotary"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required."
}

require_xcrun_tool() {
  xcrun --find "$1" >/dev/null 2>&1 || fail "xcrun $1 is required."
}

require_clean_worktree() {
  git -C "$ROOT_DIR" diff --quiet || fail "Working tree has unstaged changes."
  git -C "$ROOT_DIR" diff --cached --quiet || fail "Working tree has staged changes."
}

release_tag() {
  local tags
  local count

  tags="$(git -C "$ROOT_DIR" tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  count="$(printf '%s\n' "$tags" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$count" == "0" ]]; then
    fail "HEAD must have a vX.Y.Z release tag."
  fi

  if [[ "$count" != "1" ]]; then
    fail "HEAD must have exactly one vX.Y.Z release tag."
  fi

  printf '%s\n' "$tags"
}

sign_path() {
  local path="$1"

  codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$path"
}

submit_for_notarization() {
  local archive="$1"

  xcrun notarytool submit "$archive" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
}

require_tool git
require_tool swift
require_tool codesign
require_tool ditto
require_tool shasum
require_tool gh
require_tool spctl
require_tool xcrun
require_xcrun_tool notarytool
require_xcrun_tool stapler

[[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] || fail "DEVELOPER_ID_APPLICATION must be set."
require_clean_worktree

TAG="$(release_tag)"
gh auth status >/dev/null 2>&1 || fail "gh must be authenticated."
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --no-progress >/dev/null 2>&1; then
  fail "notarytool Keychain profile $NOTARY_PROFILE is not configured or cannot authenticate."
fi

VERSION="${TAG#v}"
COMMIT_COUNT="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
BUILD_VERSION="$VERSION.$COMMIT_COUNT"
RELEASE_DIR="$ROOT_DIR/dist/release/$TAG"
NOTARY_ZIP="$RELEASE_DIR/$APP_NAME-$TAG-notary-upload.zip"
ZIP_NAME="$APP_NAME-$TAG-macOS.zip"
FINAL_ZIP="$RELEASE_DIR/$ZIP_NAME"
SHA_FILE="$FINAL_ZIP.sha256"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

PACKAGE_APP_SKIP_AD_HOC_SIGN=1 "$ROOT_DIR/Scripts/package-app.sh" \
  --version "$VERSION" \
  --build "$BUILD_VERSION"

sign_path "$HELPER_PATH"
sign_path "$EXECUTABLE_PATH"
sign_path "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP"
submit_for_notarization "$NOTARY_ZIP"

xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
spctl --assess --type execute --verbose "$APP_DIR"

ditto -c -k --keepParent "$APP_DIR" "$FINAL_ZIP"
(
  cd "$RELEASE_DIR"
  shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
)

gh release create "$TAG" \
  "$FINAL_ZIP" \
  "$SHA_FILE" \
  --verify-tag \
  --generate-notes \
  --title "$TAG"

echo "$FINAL_ZIP"
