#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_ROOT/dist/于曦桌面宠物.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_DIR="$PROJECT_ROOT/.build"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR/ModuleCache"

/usr/bin/clang \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path="$BUILD_DIR/ModuleCache" \
  -Wall \
  -Wextra \
  -mmacosx-version-min=13.0 \
  -isysroot "$SDK_PATH" \
  -framework Cocoa \
  -framework QuartzCore \
  "$SCRIPT_DIR/Source/main.m" \
  -o "$MACOS_DIR/YuxiPet"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

SEQUENCES_DIR="$RESOURCES_DIR/Sequences"
/bin/rm -f "$RESOURCES_DIR/blink.gif" "$RESOURCES_DIR/walk.gif" \
  "$RESOURCES_DIR/wave.gif" "$RESOURCES_DIR/sleep.gif"
mkdir -p "$SEQUENCES_DIR"
for action in idle start walk stop wave sleep; do
  mkdir -p "$SEQUENCES_DIR/$action"
  cp "$PROJECT_ROOT/assets/character/sequences-v5/$action"/frame_*.png "$SEQUENCES_DIR/$action/"
done

cp "$SCRIPT_DIR/Resources/YuxiIconSource.png" "$RESOURCES_DIR/YuxiIcon.png"

/usr/bin/codesign --force --deep --sign - "$APP_DIR" >/dev/null
/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"
