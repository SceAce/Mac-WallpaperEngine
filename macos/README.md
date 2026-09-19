# Vivid macOS

[English](README.md) | [简体中文](README.zh-CN.md)

Development Wallpaper Engine player for Apple Silicon, macOS 26+, Swift 6.1+.
The app starts Vivid's existing WebUI backend, opens the panel and owns native
per-display playback. No Linux daemon is required.

## Build and launch

Restore the pinned submodules described in [dependencies](../producer/third_party/README.md), then:

```sh
brew install cmake ninja pkgconf lz4 pango fontconfig freetype libffi python
bash macos/setup-scene.sh
bash macos/setup-web.sh
bash macos/build-scene.sh
macos/.build/Vivid.app/Contents/MacOS/vivid-macos \
  --library /Users/scemac/Pictures/Wallpapers/WallpaperEngine \
  --assets /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

Setup uses proxy `http://127.0.0.1:7897` (override `VIVID_PROXY`) and verifies pinned
MoltenVK/CEF downloads. Builds never patch dependency sources. **This ad hoc signed
development bundle still requires local Python, Homebrew, DXC and MoltenVK. CEF's
Chromium sandbox is not enabled; release packaging and notarization remain pending.**

The browser panel and menu-bar Open Panel action use an automatically allocated
loopback port. Quitting the app closes its Python backend. `--no-panel` suppresses
automatic browser opening. Configuration is atomically saved under
`~/Library/Application Support/org.sceace.vivid/config.json`; `--config <file>`
selects an isolated configuration. Double-clicking the app restores saved wallpapers.

The panel supports catalog search/filter/sort, per-display selection/removal and
mute, user properties, pause/resume, volume, fit and scheduled rotation. Displays
render independently; shared clone rendering and unimplemented platform policies
are not exposed. A replacement waits for its first frame before replacing the old
wallpaper. A failed selection reports an error while keeping the previous playback.

## Content

- Scene uses the original Vivid parser and renderer through MoltenVK, IOSurface,
  XPC and Metal. Live user properties, audio settings, fit and FPS are connected.
- Video uses AVQueuePlayer/AVPlayerLooper and AVPlayerLayer with the media clock.
  Tested formats are documented; AVFoundation support does not imply every codec.
- Web uses pinned ARM64 CEF 144.0.35 in an application XPC service with accelerated
  IOSurfaces and the original JS bridge. Properties, pointer/click and pause are
  connected. The test library contains no Workshop web projects; validation uses
  the repository's own fixture.
- Presets resolve sibling `dependency` projects and typed file properties relative
  to the preset directory. Cycles and escaping project entries are rejected.

Scene supports 5–240 FPS; CEF caps at 60; video retains its media rate. Fit applies
to scene/video, while web pages lay out at screen size. System audio visualization
and media metadata are not connected. Web mute affects the browser; volume updates
HTML media and sends general properties, but custom WebAudio mixing must honor the
page callback. Pointer sampling also sees clicks over foreground windows; the
desktop window itself does not intercept Finder events.

Use `--project <directory>` for automatic type detection. Legacy `--scene` also
auto-detects types. `2519042412` is a video (`18.mp4`); the existing cloud scene is
`3265672285`, not `3265572285`. Scene needs the original installation's `assets`
directory containing `shaders/common.h`, usually absent from Workshop backups.
User content is read-only and is not redistributed.

`--mute` starts muted. `--probe-duration 5` checks the desktop after the first frame
without starting the panel or persisting settings. `--image` and
`--diagnostic-color` remain separate diagnostic sources.

## Distribution and GitHub Releases

Source builds can be shared now. Clone the repository with its pinned submodules,
then follow the build steps above:

```sh
git clone --recurse-submodules https://github.com/SceAce/Mac-WallpaperEngine.git
cd Mac-WallpaperEngine
```

GitHub's generated source archives do not contain submodule contents. The existing
`.github/workflows/release.yml` builds Linux packages only; it does not produce a
macOS app or DMG.

The generated `Vivid.app` is a development bundle, not yet a standalone download.
The scene executable links Homebrew libraries and has absolute runtime search
paths into the build tree for MoltenVK and DXC. The panel also needs external
Python. A DMG only wraps the app; it does not resolve those dependencies.

Before offering a download that runs on a clean Apple Silicon Mac, bundle the
runtime dependencies and their licenses, use bundle-relative library paths,
produce versioned Release builds, and validate installation outside the source
tree. Public distribution also needs a reviewed CEF sandbox/signing setup;
Developer ID signing and Apple notarization provide the normal Gatekeeper launch
experience. Wallpaper projects and the original Wallpaper Engine assets remain
user-provided. Those tasks are not implemented by the current build script.

## Start at login

1. Build and run `Vivid.app`, select a wallpaper, and save valid library/assets paths.
2. Keep the app at a stable path, for example `/Applications/Vivid.app`. For this
   development build, retain the original build tree and installed dependencies
   even if you copy the app there; copy a fresh app again after rebuilding.
3. Open **System Settings → General → Login Items & Extensions → Open at Login**,
   click **+**, and select `Vivid.app`. Remove it from the same list to disable it.

Playback restores after you log in. External disks containing projects or assets
must be mounted before launch. The current app also opens the browser panel at
startup. `--no-panel` suppresses that for command-line launches; the system's
login-item picker does not accept arguments. A silent login launch would need a
user LaunchAgent passing that flag or a future in-app login setting. No login
item or LaunchAgent is installed by the build scripts.

## Verification

```sh
swift test --package-path macos
ctest --test-dir macos/.build/scene --output-on-failure
macos/.build/debug/vivid-macos-selftest macos/.build/verification
VIVID_TEST_SERVICE=org.sceace.vivid.web \
macos/.build/VividSceneTest.app/Contents/MacOS/vivid-macos \
  "$PWD/macos/Tests/Fixtures/web" "$PWD/macos/Tests/Fixtures/web" \
  "$PWD/macos/.build/verification/web"
```

For HTTP integration, launch the app with an isolated `--config` and valid
`--assets`, then run `python3 macos/test-panel.py <panel URL> <library> --videos`.
It changes wallpaper assignments/settings in that isolated configuration.
`macos/test-scenes.py <library> <assets>` performs the scene matrix.
GPU/XPC checks require a logged-in graphical session.

See [panel validation](../docs/macos-panel-validation.zh-CN.md),
[scene validation](../docs/macos-scene-validation.zh-CN.md),
[development rules](DEVELOPMENT.md), [scene contract](Scene/CONTRACT.md) and
[CEF contract](Web/CONTRACT.md). The scene core is tracked directly in this repo;
external libraries retain pinned submodule revisions.
