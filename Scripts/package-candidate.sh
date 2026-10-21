#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

release_package=false
if [[ "${1:-}" == '--release' && $# == 1 ]]; then
    release_package=true
elif (( $# != 0 )); then
    print -u2 '用法：package-candidate.sh [--release]'
    exit 1
fi

# Reuses release caches. No installation, Git writes or publication.
xcodebuild -quiet -project LacEditor.xcodeproj -scheme LacEditor \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/XcodeDerivedData CODE_SIGNING_ALLOWED=NO \
    build

built_app="$PROJECT_ROOT/.build/XcodeDerivedData/Build/Products/Release/LacEditor.app"
# Only the archived installation copy advertises file handling. Never leave
# another association-enabled formal App in the reusable build directory.
stage_directory="$(mktemp -d "$PROJECT_ROOT/.build/candidate-package.XXXXXX")"
app_path="$stage_directory/LacEditor.app"
cleanup() {
    zsh "$SCRIPT_DIR/file-associations.sh" --unregister-build "$app_path" || true
    zsh "$SCRIPT_DIR/file-associations.sh" --unregister-build "$built_app" || true
    if [[ "$stage_directory" == "$PROJECT_ROOT/.build/candidate-package."* ]]; then
        /bin/rm -r "$stage_directory"
    fi
}
trap cleanup EXIT
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSHandlerRank' "$built_app/Contents/Info.plist")" == 'None' ]]
ditto "$built_app" "$app_path"
info_plist="$app_path/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == 'com.laceditor.app' ]]
stage="$(/usr/libexec/PlistBuddy -c 'Print :LacEditorReleaseStage' "$info_plist")"
if $release_package; then
    [[ -z "$stage" ]]
else
    [[ "$stage" =~ ^RC[0-9]+$ ]]
fi
/usr/libexec/PlistBuddy -c 'Set :CFBundleDocumentTypes:0:LSHandlerRank Alternate' "$info_plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "$info_plist" >/dev/null
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
mkdir -p dist
if $release_package; then
    archive_path="dist/LacEditor-${version}-arm64.zip"
else
    archive_path="dist/LacEditor-${version}-${stage}-${build_number}-arm64.zip"
fi
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
unzip -tq "$archive_path"
if $release_package; then
    print "正式版：$version（构建 $build_number）"
else
    print "正式候选：$version · $stage（构建 $build_number）"
fi
print "安装包：$PROJECT_ROOT/$archive_path"
print '试用前正常退出旧正式版，再替换「应用程序」中的 LacEditor.app。候选版沿用正式数据；实验数据独立保留。'
