#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_version='cef_binary_144.0.35+g12f1636+chromium-144.0.7559.262_macosarm64_minimal'
task_deps="$task_root/.build/dependencies/cef-download"
mkdir -p "$task_deps"
if [ ! -f "$task_deps/$task_version/include/cef_version.h" ]; then
    curl --proxy "${VIVID_PROXY:-http://127.0.0.1:7897}" --noproxy '' --fail --location --continue-at - \
        "https://cef-builds.spotifycdn.com/${task_version//+/%2B}.tar.bz2" -o "$task_deps/cef.tar.bz2"
    printf '%s  %s\n' '631cca1e0a9a7621d80a272b56cc19ec57b85345' "$task_deps/cef.tar.bz2" | shasum -a 1 -c -
    tar -xjf "$task_deps/cef.tar.bz2" -C "$task_deps"
fi
