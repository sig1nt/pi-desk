#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
install=false
build=true
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    --no-build) build=false ;;
    *) echo "Usage: $0 [--install] [--no-build]" >&2; exit 2 ;;
  esac
done
if $install && pgrep -x PiDesk >/dev/null; then
  echo "Quit PiDesk before replacing the installed application." >&2
  exit 1
fi
if $build; then swift build -c release; fi
bin="$(swift build -c release --show-bin-path)"
[[ -x "$bin/PiDesk" && -d "$bin/PiDesk_PiDesk.bundle" ]] || { echo "Release executable/resources are missing." >&2; exit 1; }
mkdir -p dist
stage="$(mktemp -d "$PWD/dist/.pidesk-build.XXXXXX")"
install_stage=""
cleanup() {
  if [[ -e "$stage/previous.app" && ! -e dist/PiDesk.app ]]; then
    mv "$stage/previous.app" dist/PiDesk.app || return
  fi
  if [[ -n "$install_stage" ]]; then
    if [[ -e "$install_stage/previous.app" && ! -e "$HOME/Applications/PiDesk.app" ]]; then
      mv "$install_stage/previous.app" "$HOME/Applications/PiDesk.app" || return
    fi
    rm -rf "$install_stage"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
app="$stage/PiDesk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/PiDesk" "$app/Contents/MacOS/PiDesk"
ditto "$bin/PiDesk_PiDesk.bundle" "$app/Contents/Resources/PiDesk_PiDesk.bundle"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PiDesk</string>
<key>CFBundleIdentifier</key><string>dev.pidesk.app</string>
<key>CFBundleName</key><string>PiDesk</string>
<key>CFBundleDisplayName</key><string>PiDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Local ad-hoc signing, not a notarized distribution build.
codesign --force --sign - "$app"
# Keep an old output until its replacement is ready. Never delete unrelated paths.
if [[ -e dist/PiDesk.app ]]; then mv dist/PiDesk.app "$stage/previous.app"; fi
mv "$app" dist/PiDesk.app
echo "Built: $PWD/dist/PiDesk.app"
if $install; then
  mkdir -p "$HOME/Applications"
  install_stage="$(mktemp -d "$HOME/Applications/.pidesk-install.XXXXXX")"
  ditto dist/PiDesk.app "$install_stage/PiDesk.app"
  if [[ -e "$HOME/Applications/PiDesk.app" ]]; then
    mv "$HOME/Applications/PiDesk.app" "$install_stage/previous.app"
  fi
  mv "$install_stage/PiDesk.app" "$HOME/Applications/PiDesk.app"
  echo "Installed: $HOME/Applications/PiDesk.app"
fi
