This directory is for third-party source dependencies used by Vivid's bundled renderer modules.

<!-- Documentation note: this file intentionally documents only source trees that Vivid builds
directly. Runtime-installed shared libraries and typelibs are described in the root README. -->

Current layout:

- `wallpaper-scene-renderer/`: Wallpaper Engine scene renderer source used by `producer/src/renderers/scene`
  and the macOS scene service, tracked directly in this repository.

The scene source is based on upstream Vivid's
`0986aa4e48540eb9ec75786bde88e458ff7dc422` and includes the macOS port. Its source
and changes are committed alongside the app; they require no separate scene fork
or build-time patches. See [source provenance](wallpaper-scene-renderer/PROVENANCE.md).

Six third-party libraries remain pinned submodules registered in the root
`.gitmodules`. Restore them and their recursive dependencies from the repository root:

```sh
git submodule update --init --recursive
```

QuickJS marks its optional `test262` suite with `update = none`. To also restore
that suite at its pinned revision:

```sh
git -C producer/third_party/wallpaper-scene-renderer/third_party/quickjs submodule update --init --recursive --checkout -- test262
```

Use the recorded revisions, not `--remote`. GitHub source archives do not include
nested submodule contents. Restoring these sources does not install system libraries
or establish macOS build compatibility. See the
[source and restoration record](../../docs/scene-source-investigation.zh-CN.md)
for the version inventory and verification scope.

Runtime builds should only ship Vivid's compiled artifacts, not these source trees.

Push this repository to publish both the scene core and the app. The dependency
submodules retain their official upstream URLs and recorded revisions.
