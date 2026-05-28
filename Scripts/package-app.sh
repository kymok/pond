#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Pond"
EXECUTABLE_NAME="Pond"
CLI_NAME="taskpond"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Library/Helpers"
PACKAGING_RESOURCES_DIR="$ROOT_DIR/Packaging/Resources"
ICON_NAME="Pond"
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

find_icon_tool() {
  local xcode_app="${XCODE_APP:-/Applications/Xcode.app}"
  local tool_dir="$xcode_app/Contents/Applications/Icon Composer.app/Contents/Executables"

  if [[ -x "$tool_dir/ictool" ]]; then
    printf '%s\n' "$tool_dir/ictool"
  elif [[ -x "$tool_dir/icontool" ]]; then
    printf '%s\n' "$tool_dir/icontool"
  else
    return 1
  fi
}

create_icns_from_png() {
  local source_png="$1"
  local output_icns="$2"
  local temp_dir="$3"
  local iconset_dir="$temp_dir/$ICON_NAME.iconset"

  mkdir -p "$iconset_dir"

  sips -z 16 16 "$source_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64 "$source_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$source_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$source_png" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset_dir" -o "$output_icns"
}

create_icns_from_icon_file() {
  local source_icon="$1"
  local output_icns="$2"
  local temp_dir

  (
    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' EXIT
    render_icon_file_to_png "$source_icon" "$temp_dir/$ICON_NAME.png"
    create_icns_from_png "$temp_dir/$ICON_NAME.png" "$output_icns" "$temp_dir"
  )
}

create_icns_from_single_png() {
  local source_png="$1"
  local output_icns="$2"
  local temp_dir

  (
    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' EXIT
    create_icns_from_png "$source_png" "$output_icns" "$temp_dir"
  )
}

render_icon_file_to_png() {
  local source_icon="$1"
  local output_png="$2"
  local icon_tool
  local fallback_png

  if icon_tool="$(find_icon_tool)" && "$icon_tool" "$source_icon" --export-image --output-file "$output_png" --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null; then
    return 0
  fi

  # Some Icon Composer bundles do not open in ictool, but still include usable source PNG assets.
  if [[ -d "$source_icon/Assets" ]]; then
    fallback_png="$(find "$source_icon/Assets" -maxdepth 1 -type f -name '*.png' ! -name '*dark*' -print -quit)"
    if [[ -z "$fallback_png" ]]; then
      fallback_png="$(find "$source_icon/Assets" -maxdepth 1 -type f -name '*.png' -print -quit)"
    fi
  fi
  if [[ -z "$fallback_png" ]]; then
    echo "No PNG assets found in $source_icon" >&2
    return 1
  fi

  cp "$fallback_png" "$output_png"
}

install_app_icon() {
  local output_icns="$RESOURCES_DIR/$ICON_NAME.icns"
  local source_icns="$PACKAGING_RESOURCES_DIR/$ICON_NAME.icns"
  local source_icon="$PACKAGING_RESOURCES_DIR/$ICON_NAME.icon"
  local source_iconset="$PACKAGING_RESOURCES_DIR/$ICON_NAME.iconset"
  local source_png="$PACKAGING_RESOURCES_DIR/$ICON_NAME.png"

  if [[ -f "$source_icns" ]]; then
    cp "$source_icns" "$output_icns"
  elif [[ -d "$source_icon" ]]; then
    create_icns_from_icon_file "$source_icon" "$output_icns"
  elif [[ -d "$source_iconset" ]]; then
    iconutil -c icns "$source_iconset" -o "$output_icns"
  elif [[ -f "$source_png" ]]; then
    create_icns_from_single_png "$source_png" "$output_icns"
  fi
}

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

quit_running_app
swift build -c release --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR"

cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -n "$MARKETING_VERSION" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$CONTENTS_DIR/Info.plist"
fi

cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$ROOT_DIR/.build/release/$CLI_NAME" "$HELPERS_DIR/$CLI_NAME"

install_app_icon

chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME" "$HELPERS_DIR/$CLI_NAME"

if [[ "${PACKAGE_APP_SKIP_AD_HOC_SIGN:-0}" != "1" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "$APP_DIR"
