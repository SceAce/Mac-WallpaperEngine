# Vivid macOS

[English](README.md) | [简体中文](README.zh-CN.md)

Development player for Apple Silicon, macOS 26+, Swift 6.1+. Real Wallpaper Engine
scene packages run in the restored Vivid C++ renderer. Vulkan/MoltenVK renders into
IOSurfaces; an XPC service transfers completed frames to the native Metal desktop
presenter. SceneScript, effects, particles, rope, text and embedded video reuse the
original scene pipeline. See the [validation record](../docs/macos-scene-validation.zh-CN.md)
for tested content and remaining compatibility limitations.

## Build

Restore the pinned recursive submodules as described in
[third-party dependencies](../producer/third_party/README.md), then:

```sh
brew install cmake ninja pkgconf lz4 pango fontconfig freetype libffi
bash macos/setup-scene.sh
bash macos/build-scene.sh
```

Setup downloads checksum-verified MoltenVK 1.4.2 through proxy
`http://127.0.0.1:7897` (override `VIVID_PROXY`) and builds the pinned arm64 DXC.
Builds never rewrite dependency sources. The app is ad hoc signed at
`macos/.build/Vivid.app`. **This development bundle uses external Homebrew, DXC and
MoltenVK libraries; it is not a self-contained, notarized release.**

## Play a scene

Both the wallpaper project and Wallpaper Engine's original `assets` directory are
required. A Workshop package usually does not include common shaders. User files
are read without modification; assets are not bundled or redistributed.

```sh
macos/.build/Vivid.app/Contents/MacOS/vivid-macos \
  --scene /Users/scemac/Pictures/Wallpapers/WallpaperEngine/3220055919 \
  --assets /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

Use the menu-bar icon to pause/resume or quit. `--mute` disables scene sound;
audio is enabled on the primary display only. System audio capture / spectrum and
system media integration are not connected yet. Pointer position and left-button
state are sampled at 30 Hz without taking clicks away from Finder. Currently the
pointer also tracks over foreground windows; desktop-only click routing requires
further acceptance work.

Scene output targets 30 FPS at the display's backing resolution. GPU texture copies
and bounded frame leases keep CPU readback out of the player. Shader/texture caches
and renderer logs are under `~/Library/Caches/org.sceace.vivid/scene/`.

`--probe-duration 30` runs a timed desktop check. `--image <file>` and
`--diagnostic-color <r> <g> <b>` retain the separate P0 diagnostic renderer.
Launch the app bundle executable for scene playback: the bare SwiftPM executable
does not contain the XPC service.

## Verify

```sh
ctest --test-dir macos/.build/scene --output-on-failure
macos/.build/debug/vivid-macos-selftest macos/.build/verification
macos/.build/VividSceneTest.app/Contents/MacOS/vivid-macos \
  /Users/scemac/Pictures/Wallpapers/WallpaperEngine/3220055919 \
  /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets \
  macos/.build/verification/rope
python3 macos/test-scenes.py \
  /Users/scemac/Pictures/Wallpapers/WallpaperEngine \
  /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

The scene self-test uses the real XPC service and Metal readback. It samples frames
1/45/90, checks image detail, opaque coverage and change, holds all three leases to check backpressure,
checks pause/resume, sends pointer/button input and verifies stop. FPS excludes PNG
capture and intentional pauses. The matrix writes `results.json` plus per-scene
PNGs/logs under `.build/verification/matrix`. An animation test can fail for an
authored static or audio-only scene; review the content instead of weakening the check.
These are playback tests, not a pixel-equivalence claim against Windows.

GPU/XPC/desktop checks require the logged-in graphics session. Pure project tests
cover property types and project paths; the original `scene_identity` test covers
shared scene identity behavior. The earlier [frame transport probe](Probes/FrameTransport)
also tests malformed/stale messages and producer death, but is separate from the
actual scene service.

Follow [development rules](DEVELOPMENT.md) and the [scene contract](Scene/CONTRACT.md).
The scene core and its macOS changes are tracked directly in this repository under
`producer/third_party/wallpaper-scene-renderer/`. A push of this repository includes
both the core and the app. Its third-party libraries remain pinned submodules;
restore them with the commands above. No source patch scripts are used.
