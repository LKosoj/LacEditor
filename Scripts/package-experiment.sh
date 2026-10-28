#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

app_path='.build/XcodeDerivedData/Build/Products/Experimental/LacEditor 实验版.app'
cleanup() {
    if [[ -d "$app_path" ]]; then
        zsh "$SCRIPT_DIR/file-associations.sh" --unregister-build "$PROJECT_ROOT/$app_path" || true
    fi
}
trap cleanup EXIT

# Reuse the existing dependency/build cache; never install over the formal App.
xcodebuild -quiet \
    -project LacEditor.xcodeproj \
    -scheme 'LacEditor UI Experiment' \
    -configuration Experimental \
    -destination 'platform=macOS' \
    -derivedDataPath .build/XcodeDerivedData \
    CODE_SIGNING_ALLOWED=NO build

info_plist="$app_path/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" \
    == 'com.laceditor.ui-experiment' ]] || { print -u2 '实验版标识校验失败。'; exit 1; }
if /usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "$info_plist" >/dev/null 2>&1; then
    print -u2 '实验版不应注册 Finder 文件关联。'
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
iteration="$(/usr/libexec/PlistBuddy -c 'Print :LacEditorExperimentIteration' "$info_plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
codesign --force --sign - "$app_path/Contents/MacOS/pandoc"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
sh "$SCRIPT_DIR/verify-bundled-pandoc.sh" "$app_path"
mkdir -p dist
archive_path="dist/LacEditor-${version}-${iteration}-${build_number}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
unzip -tq "$archive_path"
print "实验版：$version · $iteration（构建 $build_number）"
print "安装包：$PROJECT_ROOT/$archive_path"
print '解压后将「LacEditor 实验版.app」拖入「应用程序」，可与正式版同时保留。'
