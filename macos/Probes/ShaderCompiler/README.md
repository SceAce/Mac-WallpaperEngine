# Native Shader Compiler Probe

Build the scene core's pinned DXC dependency (`42da79c4...`) without source changes:

```sh
cmake -S producer/third_party/wallpaper-scene-renderer/third_party/DirectXShaderCompiler \
  -B macos/.build/dxc -G Ninja -C macos/Probes/ShaderCompiler/DXC.cmake
cmake --build macos/.build/dxc --target dxcompiler dxc --parallel 4
macos/.build/dxc/bin/dxc --version
macos/.build/dxc/bin/dxc -spirv -fspv-target-env=vulkan1.1 -T vs_6_0 -E vertexMain \
  macos/Probes/ShaderCompiler/quad.hlsl -Fo macos/.build/dxc/quad.vert.spv
macos/.build/dxc/bin/dxc -spirv -fspv-target-env=vulkan1.1 -T ps_6_0 -E fragmentMain \
  macos/Probes/ShaderCompiler/quad.hlsl -Fo macos/.build/dxc/quad.frag.spv
```

This verifies native compiler/tool output only. The fixture does not prove
Wallpaper Engine material compatibility or replace geometry shaders. The later
[scene implementation](../../README.md) supplies platform-aware DXC staging,
video backends, Vulkan device selection, IOSurface output and a bounded rope
geometry translation. Its real-content tests are recorded separately.
