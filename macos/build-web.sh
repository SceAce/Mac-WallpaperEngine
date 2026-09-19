#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_cef="$task_root/.build/dependencies/cef-download/cef_binary_144.0.35+g12f1636+chromium-144.0.7559.262_macosarm64_minimal"
if [ ! -f "$task_cef/include/cef_version.h" ]; then
    echo 'Run bash macos/setup-web.sh first.' >&2
    exit 1
fi
cmake -S "$task_root/Web" -B "$task_root/.build/web" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$task_root/.build/web" --parallel 6
task_bundle="$task_root/.build/web/VividWebService.xpc"
task_frameworks="$task_bundle/Contents/Frameworks"
mkdir -p "$task_frameworks"
ditto "$task_cef/Release/Chromium Embedded Framework.framework" "$task_frameworks/Chromium Embedded Framework.framework"
mkdir -p "$task_bundle/Contents/Resources"
cp "$task_cef/LICENSE.txt" "$task_bundle/Contents/Resources/CEF-LICENSE.txt"
cp "$task_cef/CREDITS.html" "$task_bundle/Contents/Resources/CEF-CREDITS.html"
for task_suffix in '' ' (Renderer)' ' (GPU)' ' (Plugin)'; do
    task_name="VividWeb Helper$task_suffix"
    task_helper="$task_frameworks/$task_name.app/Contents"
    mkdir -p "$task_helper/MacOS"
    cp "$task_root/.build/web/VividWebHelper" "$task_helper/MacOS/$task_name"
    /usr/bin/plutil -create xml1 "$task_helper/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "org.sceace.vivid.web.helper$(echo "$task_suffix" | tr -cd 'A-Za-z')" "$task_helper/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string "$task_name" "$task_helper/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL "$task_helper/Info.plist"
    /usr/bin/plutil -insert LSUIElement -bool true "$task_helper/Info.plist"
    codesign --force --sign - "$task_frameworks/$task_name.app"
done
codesign --force --sign - "$task_frameworks/Chromium Embedded Framework.framework"
codesign --force --sign - "$task_bundle"
