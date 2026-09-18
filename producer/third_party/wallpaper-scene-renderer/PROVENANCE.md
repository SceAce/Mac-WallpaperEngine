# Scene source provenance

This directory is tracked directly in `SceAce/Mac-WallpaperEngine`, together with
its macOS adaptations. It is not a separate scene submodule.

- Upstream: <https://github.com/ayasa520/wallpaper-scene-renderer>
- Upstream baseline: `0986aa4e48540eb9ec75786bde88e458ff7dc422`
- Local macOS migration snapshot: `1fd6e58ee614dad9cae932592bbb7717c2e0726f`
- License: [GPL-2.0](LICENSE); upstream notices and bundled library notices are retained.

The migration snapshot was committed locally before importing its source into the
application repository. The 293 imported files match that snapshot byte for byte;
its nested `.gitmodules` was replaced by dependency entries in the root repository.
The snapshot ID records provenance and is not a commit that a fresh clone needs to
fetch from the upstream scene repository.

DXC, Eigen, SPIRV-Reflect, miniaudio, nlohmann/json and QuickJS remain official
upstream submodules at their original recorded revisions. Their paths are declared
in the root [`.gitmodules`](../../../.gitmodules). Restore them from the repository
root with `git submodule update --init --recursive`.

The macOS port splits Linux and macOS texture export and video decoding, adds
IOSurface output and rope geometry translation, and corrects font selection,
animation-free skeleton loading and color attachment preservation. No source
patches are applied during builds. Implementation and verification details are
recorded in [the macOS scene validation report](../../../docs/macos-scene-validation.zh-CN.md).
