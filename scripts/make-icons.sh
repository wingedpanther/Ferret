#!/bin/zsh
# Renders Resources/Icon/*.svg into the files the app bundle uses:
#   Resources/AppIcon.icns                 app icon (Dock, Finder, Settings)
#   Resources/MenuBarIcon.png, @2x.png     menu bar template image
#   Resources/GitHubMark.png, @2x.png      Settings link (GitHub's Octicon mark-github, MIT)
# Needs rsvg-convert (brew install librsvg). The outputs are committed, so bundle.sh doesn't need it.
set -euo pipefail
cd "${0:A:h}/.."

set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size Resources/Icon/ferret.svg -o "$set_dir/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) Resources/Icon/ferret.svg -o "$set_dir/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set_dir" -o Resources/AppIcon.icns
rm -rf "${set_dir:h}"

rsvg-convert -w 18 -h 18 Resources/Icon/menubar.svg -o Resources/MenuBarIcon.png
rsvg-convert -w 36 -h 36 Resources/Icon/menubar.svg -o Resources/MenuBarIcon@2x.png
rsvg-convert -w 16 -h 16 Resources/Icon/github.svg -o Resources/GitHubMark.png
rsvg-convert -w 32 -h 32 Resources/Icon/github.svg -o Resources/GitHubMark@2x.png
echo "made Resources/AppIcon.icns, MenuBarIcon.png and GitHubMark.png"
