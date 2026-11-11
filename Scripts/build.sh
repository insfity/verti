#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${BUILD_ROOT:-$project_root/.build}"
output_root="${1:-$project_root/dist}"
mkdir -p "$build_root/module-cache" "$output_root"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
for architecture in arm64; do
    swift build --disable-sandbox --package-path "$project_root" --scratch-path "$build_root/$architecture" -c release --arch "$architecture" --product VerticalStudio
done
app_bundle="$output_root/竖影.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$build_root/arm64/arm64-apple-macosx/release/VerticalStudio" "$app_bundle/Contents/MacOS/VerticalStudio"
cp "$project_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
echo "Built $app_bundle (Apple silicon, macOS 15+)"
