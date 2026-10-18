#!/bin/zsh
# Builds a Release copy and installs it in /Applications (quits the running app first).
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
xcodebuild -project IdiophileOne.xcodeproj -scheme IdiophileOne -configuration Release \
  -derivedDataPath build -quiet build
osascript -e 'tell application "Idiophile One" to quit' 2>/dev/null || true
sleep 1
ditto "build/Build/Products/Release/Idiophile One.app" "/Applications/Idiophile One.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Idiophile One.app"
echo "Installed /Applications/Idiophile One.app"
