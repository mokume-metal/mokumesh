#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# mokumesh.app を組み、DMG に包む。ローカル (make dmg) と CI (release.yml) の唯一の入口で、
# CI はこれを呼ぶだけにする (ローカルと CI の乖離を作らない。mokume の ADR-0001 原則 8)。
#
#   scripts/build-dmg.sh [VERSION]     既定は 0.0.0-dev。出力は dist/mokumesh-<VERSION>.dmg
#
# **公証 (notarization) も Developer ID の署名もしない。** Apple Silicon は署名の無い
# 実行ファイルを起動しないので ad-hoc 署名 (`-`) だけを付ける。Gatekeeper は初回に止めるので、
# 開き方は README の「入れる」に書く。Developer ID に進むときは SIGN_IDENTITY を差し替え、
# DMG を作った後に notarytool と stapler の段を足す。
set -euo pipefail

VERSION="${1:-${VERSION:-0.0.0-dev}}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="io.github.mokume-metal.mokumesh"
# 床は Package.swift の platforms と同じ (mokume の ADR-0009)
MINIMUM_SYSTEM="26.0"

# Info.plist に載るので、版として読めない綴りは先に止める
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "版の綴りとして読めない: $VERSION (例 0.1.0)" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/mokumesh.app"
DMG="$DIST/mokumesh-$VERSION.dmg"

cd "$ROOT"
swift build -c release --package-path App --product mokumesh
BIN="$(swift build -c release --package-path App --show-bin-path)"

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN/mokumesh" "$APP/Contents/MacOS/mokumesh"
# framework を macOS の形 (実体は Versions/A、他はそこを指す symlink) に組み直して写す。
# mokume-syphon の Release の zip は symlink を潰して焼かれており (v0.3.0 時点)、
# Versions/Current と最上位の Headers などが実体の写しになっている。そのままだと
# codesign が「bundle format is ambiguous」で署名を拒む
FRAMEWORK="$APP/Contents/Frameworks/Syphon.framework"
mkdir -p "$FRAMEWORK/Versions"
ditto "$BIN/Syphon.framework/Versions/A" "$FRAMEWORK/Versions/A"
rm -rf "$FRAMEWORK/Versions/A/_CodeSignature" "$FRAMEWORK/Versions/A/Headers" "$FRAMEWORK/Versions/A/Modules"
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/Syphon "$FRAMEWORK/Syphon"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"

# SwiftPM が付ける rpath は @loader_path (bin path に framework が並ぶ前提) だけなので、
# .app の中の Frameworks を引けるように足す
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/mokumesh"

# CFBundleVersion は数字とドットしか許されないので、-dev などの後ろを落とす
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleExecutable</key><string>mokumesh</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>mokumesh</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>${VERSION%%-*}</string>
    <key>LSMinimumSystemVersion</key><string>$MINIMUM_SYSTEM</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 内側から外側へ署名する (--deep は使わない — 何に署名したかが読めなくなる)。
# install_name_tool で実行ファイルの署名は壊れているので、ここで付け直す
codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORK"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

# DMG の中身: .app と /Applications への symlink (ドラッグで入れられるように)
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/mokumesh.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "mokumesh $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "$DMG"
