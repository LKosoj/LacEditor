#!/bin/sh
set -eu

app_path=$1
pandoc="$app_path/Contents/MacOS/pandoc"
test -x "$pandoc"
test "$(lipo -archs "$pandoc")" = arm64
test -s "$app_path/Contents/Resources/Pandoc/COPYRIGHT"
test -s "$app_path/Contents/Resources/Pandoc/COPYING"
test -s "$app_path/Contents/Resources/Pandoc/import-images.lua"
test "$(env PATH=/usr/bin:/bin "$pandoc" --version | head -n 1)" = 'pandoc 3.13'
codesign --verify --strict "$pandoc"
