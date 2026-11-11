#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${BUILD_ROOT:-$project_root/.build/validation}"
mkdir -p "$build_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
swift run --disable-sandbox --package-path "$project_root" --scratch-path "$build_root" CoreValidation "$@"
