#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
python3 scripts/release_metadata.py

APP_DIR="$PROJECT_DIR/.build.noindex/cduyzhMenuBar.app"
python3 scripts/app_common.py require-stopped "$APP_DIR"
BUILD_SOURCE_HASH="$(python3 scripts/release_metadata.py --source-hash)"

echo "[1/4] 编译 Release…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

if [ ! -f "$BIN_DIR/cduyzhMenuBar" ]; then
    echo "未找到编译产物：$BIN_DIR/cduyzhMenuBar" >&2
    exit 1
fi
if [ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    echo "未找到应用图标，请先运行 swift scripts/generate_icon.swift。" >&2
    exit 1
fi

echo "[2/4] 打包 macOS 应用…"
mkdir -p "$PROJECT_DIR/.build.noindex"
touch "$PROJECT_DIR/.build.noindex/.metadata_never_index"
BUILD_WORK="$(mktemp -d "$PROJECT_DIR/.build.noindex/.bundle.XXXXXX")"
cleanup() { rm -rf "$BUILD_WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGED_APP="$BUILD_WORK/cduyzhMenuBar.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/cduyzhMenuBar" "$STAGED_APP/Contents/MacOS/cduyzhMenuBar"
cp "$PROJECT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/AppIcon_1024.png" "$STAGED_APP/Contents/Resources/AppIcon_1024.png"
python3 scripts/release_metadata.py --stamp-bundle "$STAGED_APP" --expected-source-hash "$BUILD_SOURCE_HASH"

echo "[3/4] 固定应用标识并验证签名…"
codesign --force --sign - \
    --requirements '=designated => identifier "com.cduyzh.menu-bar"' \
    "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
python3 scripts/finalize_build.py "$STAGED_APP"

echo "[4/4] 已生成：$APP_DIR"
