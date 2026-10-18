#!/bin/zsh
# Builds a universal Release and packages it for GitHub Releases: dist/Idiophile-One-<version>.dmg,
# .zip and SHA256SUMS.txt. Usage: scripts/release.sh 0.1.0-alpha.1
# Without an Apple Developer ID the app is signed ad hoc and not notarised.
set -euo pipefail
cd "${0:A:h}/.."
version=${1:?usage: scripts/release.sh <version>}
name="Idiophile-One-$version"
app="build/release/Build/Products/Release/Idiophile One.app"

xcodegen generate -q
rm -rf build/release dist
xcodebuild -project IdiophileOne.xcodeproj -scheme IdiophileOne -configuration Release \
  -derivedDataPath build/release -quiet ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

mkdir -p dist/dmg
ditto "$app" "dist/dmg/Idiophile One.app"
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname "Idiophile One $version" -srcfolder dist/dmg -ov -format UDZO "dist/$name.dmg"
rm -rf dist/dmg
ditto -c -k --keepParent "$app" "dist/$name.zip"
(cd dist && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt)
lipo -archs "$app/Contents/MacOS/Idiophile One"
cat dist/SHA256SUMS.txt
