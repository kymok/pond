#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Pond"
EXECUTABLE_NAME="Pond"
CLI_NAME="taskpond"
PROJECT_PATH="$ROOT_DIR/Pond.xcodeproj"
SCHEME_NAME="Pond"
CONFIGURATION="Release"
BUILD_PRODUCTS_DIR="$ROOT_DIR/tmp/XcodeBuild/$CONFIGURATION"
DERIVED_DATA_DIR="$ROOT_DIR/tmp/DerivedData"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Library/Helpers"
APP_BUNDLE_ID="dev.kymok.pond"
MARKETING_VERSION=""
BUILD_VERSION=""

usage() {
  echo "Usage: $0 [--version X.Y.Z --build X.Y.Z.W]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      MARKETING_VERSION="$2"
      shift 2
      ;;
    --build)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
      BUILD_VERSION="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$MARKETING_VERSION$BUILD_VERSION" && ( -z "$MARKETING_VERSION" || -z "$BUILD_VERSION" ) ]]; then
  usage
  exit 2
fi

quit_running_app() {
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi

  for _ in {1..50}; do
    if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
      return
    fi

    sleep 0.1
  done

  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
}

xcodebuild_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME_NAME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_DIR"
  CONFIGURATION_BUILD_DIR="$BUILD_PRODUCTS_DIR"
  CODE_SIGNING_ALLOWED=NO
)

rm -rf "$APP_DIR"
mkdir -p "$ROOT_DIR/dist"

if [[ -n "$MARKETING_VERSION" ]]; then
  xcodebuild_args+=(
    MARKETING_VERSION="$MARKETING_VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_VERSION"
  )
fi

xcodebuild "${xcodebuild_args[@]}" build
ditto "$BUILD_PRODUCTS_DIR/$APP_NAME.app" "$APP_DIR"

chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME" "$HELPERS_DIR/$CLI_NAME"

if [[ "${PACKAGE_APP_SKIP_AD_HOC_SIGN:-0}" != "1" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR"
fi

quit_running_app

echo "$APP_DIR"
