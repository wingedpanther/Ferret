#!/bin/zsh
# Builds Ferret.app into ./build and signs it ad hoc.
#   scripts/bundle.sh            build only
#   scripts/bundle.sh --install  also copy to ~/Applications and relaunch
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
app=build/Ferret.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Ferret "$app/Contents/MacOS/Ferret"
cp Resources/JetBrainsMono.ttf Resources/JetBrainsMono-OFL.txt LICENSE Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/GitHubMark.png Resources/GitHubMark@2x.png "$app/Contents/Resources/"

# Bundle fsearch so Ferret works on machines without it. Prefer the official release build:
# a local `cargo build` targets this Mac's CPU and may not run on older Apple Silicon.
# Override with FSEARCH_BIN=/path/to/fsearch.
fsearch_src="${FSEARCH_BIN:-}"
if [[ -z "$fsearch_src" ]]; then
  cached=build/cache/fsearch
  if [[ ! -x "$cached" ]]; then
    mkdir -p build/cache
    curl -sSfL https://github.com/noahdunnagan/fsearch/releases/latest/download/fsearch-aarch64-apple-darwin.tar.gz \
      | tar xz -C build/cache 2>/dev/null || true
  fi
  if [[ -x "$cached" ]]; then
    fsearch_src="$cached"
  elif [[ -x ~/.local/bin/fsearch ]]; then
    fsearch_src=~/.local/bin/fsearch
    echo "warning: couldn't download the fsearch release; bundling ~/.local/bin/fsearch (built for this Mac's CPU)"
  fi
fi
if [[ -n "$fsearch_src" ]]; then
  cp "$fsearch_src" "$app/Contents/MacOS/fsearch"
  codesign --force --sign - "$app/Contents/MacOS/fsearch"
  echo "bundled fsearch from $fsearch_src"
else
  echo "warning: no fsearch to bundle; Ferret will need ~/.local/bin/fsearch"
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.wingedpanther.ferret</string>
  <key>CFBundleName</key><string>Ferret</string>
  <key>CFBundleDisplayName</key><string>Ferret</string>
  <key>CFBundleExecutable</key><string>Ferret</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Vivek · MIT licence</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "built $app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Ferret 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Ferret.app
  cp -R "$app" ~/Applications/
  open ~/Applications/Ferret.app
  echo "installed ~/Applications/Ferret.app"
fi
