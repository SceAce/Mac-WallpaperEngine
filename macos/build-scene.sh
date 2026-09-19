#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
if command -v brew >/dev/null 2>&1; then
    task_ffi="$(brew --prefix libffi)"
    export PKG_CONFIG_PATH="$task_ffi/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
cmake -S "$task_root/Scene" -B "$task_root/.build/scene" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "$task_root/.build/scene" --parallel 6
swift build --package-path "$task_root" -Xswiftc -warnings-as-errors
bash "$task_root/build-web.sh"
task_bundle="$task_root/.build/Vivid.app"
mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/XPCServices"
cp "$task_root/.build/debug/vivid-macos" "$task_bundle/Contents/MacOS/"
cp "$task_root/Scene/App.plist" "$task_bundle/Contents/Info.plist"
mkdir -p "$task_bundle/Contents/Resources/webui"
cp "$task_root/../producer/src/webui/"*.py "$task_root/../producer/src/webui/"*.js \
   "$task_root/../producer/src/webui/"*.css "$task_root/../producer/src/webui/"*.html \
   "$task_bundle/Contents/Resources/webui/"
cp -R "$task_root/.build/scene/VividSceneService.xpc" "$task_bundle/Contents/XPCServices/"
ditto "$task_root/.build/web/VividWebService.xpc" "$task_bundle/Contents/XPCServices/VividWebService.xpc"
codesign --force --sign - "$task_bundle/Contents/XPCServices/VividSceneService.xpc"
codesign --force --sign - "$task_bundle"
task_test_bundle="$task_root/.build/VividSceneTest.app"
mkdir -p "$task_test_bundle/Contents/MacOS" "$task_test_bundle/Contents/XPCServices"
cp "$task_root/.build/debug/vivid-scene-selftest" "$task_test_bundle/Contents/MacOS/vivid-macos"
cp "$task_root/Scene/App.plist" "$task_test_bundle/Contents/Info.plist"
cp -R "$task_root/.build/scene/VividSceneService.xpc" "$task_test_bundle/Contents/XPCServices/"
ditto "$task_root/.build/web/VividWebService.xpc" "$task_test_bundle/Contents/XPCServices/VividWebService.xpc"
codesign --force --sign - "$task_test_bundle/Contents/XPCServices/VividSceneService.xpc"
codesign --force --sign - "$task_test_bundle"
echo "Built $task_bundle (development dependencies remain outside the bundle)"
