# Vivid for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

Wallpaper Engine player for **Apple Silicon (M series), macOS 26+**. This fork of
[ayasa520/Vivid](https://github.com/ayasa520/Vivid) maintains the native macOS app,
Vivid scene compatibility core, original WebUI and CEF JavaScript bridge.

- Scene: original C++ renderer, MoltenVK, IOSurface and Metal.
- Video: native AVFoundation playback and looping.
- Web: bundled CEF with wallpaper properties and mouse interaction.
- Panel: library browsing, per-display assignments, settings and scheduled rotation.

## Build and run

```sh
git clone --recurse-submodules https://github.com/SceAce/Mac-WallpaperEngine.git
cd Mac-WallpaperEngine
brew install cmake ninja pkgconf lz4 pango fontconfig freetype libffi python
bash macos/setup-scene.sh
bash macos/setup-web.sh
bash macos/build-scene.sh
open macos/.build/Vivid.app
```

Requires Swift 6.1+. Setup defaults to proxy `http://127.0.0.1:7897`; configure
`VIVID_PROXY` for your environment. The panel opens at `http://127.0.0.1:8765/`.
Choose your wallpaper library and the original Wallpaper Engine `assets` folder.
Both may be on a local disk; standalone video wallpapers do not require assets.

See the [complete build, playback and login guide](macos/README.md).
**The app remains a development bundle with external runtime dependencies,
ad hoc signing and CEF sandboxing disabled.** Standalone distribution and
notarization are pending. Content compatibility and test limits are recorded in
[panel validation](docs/macos-panel-validation.zh-CN.md) and
[scene validation](docs/macos-scene-validation.zh-CN.md).

## Repository layout

- `macos/`: native app, XPC scene/web services, WebUI, JS bridge, build scripts and tests.
- `producer/third_party/`: scene core and six pinned dependency submodules. The
  historical path is retained for existing submodule and DXC build directories.
- `docs/`: architecture decisions, source provenance and macOS validation records.

Linux clients, daemon, packaging and release workflows have been removed. Use
[upstream Vivid](https://github.com/ayasa520/Vivid) for Linux. Platform files inside
pinned third-party libraries are retained as upstream dependencies; they do not
add a Linux application target. See the [cleanup record](docs/macos-only-cleanup.zh-CN.md).

## License and attribution

[GPL-2.0](LICENSE). This fork retains Vivid's source and compatibility work,
[scene provenance](producer/third_party/wallpaper-scene-renderer/PROVENANCE.md),
and dependency licenses. Thanks to upstream Vivid, wallpaper-scene-renderer and
[waywallen](https://github.com/waywallen). Wallpapers and original Wallpaper Engine
assets are user-provided and are not redistributed.
