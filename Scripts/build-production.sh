#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

(( $# == 0 )) || { print -u2 '用法：build-production.sh'; exit 1; }

# Release gate plus the shared packaging. No version bump, Git writes,
# publication or installation.
zsh "$SCRIPT_DIR/verify-release.sh"
zsh "$SCRIPT_DIR/package-release.sh"

version="$(tr -d '[:space:]' < VERSION)"
archive_name="LacEditor-${version}-arm64.zip"
(cd dist && shasum -a 256 "$archive_name" > "$archive_name.sha256")

print
print "发布文件已就绪（$PROJECT_ROOT/dist）："
print "  $archive_name"
print "  $archive_name.sha256"
print
print '确认版本提交与标签已推送后，上传到 GitHub Release：'
print "  gh release create v$version 'dist/$archive_name' 'dist/$archive_name.sha256' --repo LKosoj/LacEditor --title 'LacEditor $version' --notes-file 'docs/releases/$version.md'"
