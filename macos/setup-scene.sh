#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_dependencies="$task_root/.build/dependencies"
task_archive="$task_dependencies/MoltenVK-macos-1.4.2.tar"
task_checksum=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e
task_dxc="$task_root/../producer/third_party/wallpaper-scene-renderer/third_party/DirectXShaderCompiler"

for task_tool in cmake ninja swift pkg-config curl; do
    command -v "$task_tool" >/dev/null || { echo "Missing build tool: $task_tool" >&2; exit 1; }
done
pkg-config --exists liblz4 pangocairo pangoft2 fontconfig freetype2 || {
    echo "Install scene dependencies: brew install cmake ninja pkgconf lz4 pango fontconfig freetype libffi" >&2
    exit 1
}
test -f "$task_dxc/CMakeLists.txt" || {
    echo "Restore the pinned recursive scene submodules before setup." >&2
    exit 1
}
mkdir -p "$task_dependencies"
if ! test -f "$task_archive"; then
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 900 \
        --proxy "${VIVID_PROXY:-http://127.0.0.1:7897}" \
        https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar \
        --output "$task_archive.download"
    mv "$task_archive.download" "$task_archive"
fi
task_actual="$(shasum -a 256 "$task_archive")"
if [[ "${task_actual%% *}" != "$task_checksum" ]]; then
    echo "MoltenVK archive checksum mismatch: $task_archive" >&2
    exit 1
fi
tar -xf "$task_archive" -C "$task_dependencies"
cmake -S "$task_dxc" -B "$task_root/.build/dxc" -G Ninja \
    -C "$task_root/Probes/ShaderCompiler/DXC.cmake"
cmake --build "$task_root/.build/dxc" --target dxcompiler dxc --parallel "${VIVID_BUILD_JOBS:-4}"
for task_component in dxc-headers dxcompiler dxc; do
    cmake --install "$task_root/.build/dxc" --prefix "$task_root/.build/dxc-stage" \
        --component "$task_component"
done
echo "Scene dependencies ready. Run bash macos/build-scene.sh."
