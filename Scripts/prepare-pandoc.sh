#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname "$script_directory")
archive="$project_directory/Vendor/Pandoc/pandoc-3.13-arm64-macOS.zip"
destination="$project_directory/LacEditor/Resources/Pandoc/pandoc"

printf '%s  %s\n' 'f436d18bebbfb3ddd326597686dacab9fac5dc23bd060495020f35a28a43a7c3' "$archive" | shasum -a 256 -c -
mkdir -p "$(dirname "$destination")"
temporary=$(mktemp "${destination}.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
unzip -p "$archive" pandoc-3.13-arm64/bin/pandoc > "$temporary"
chmod 755 "$temporary"
if ! cmp -s "$temporary" "$destination"; then
    mv -f "$temporary" "$destination"
fi
