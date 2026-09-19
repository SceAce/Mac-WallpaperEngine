# Scene Platform Boundary

The scene parser, SceneScript host, animation clock, particle simulation and render
graph remain in the pinned Vivid renderer. Platform implementation files are
selected by CMake, not patched during a build.

- Vulkan device discovery enables supported features. A material requiring an
  unavailable stage must be translated by its particle render plan or rejected
  before pipeline creation. Geometry support is not a prerequisite for image scenes.
- Linux owns DMA-BUF/FD allocation and GStreamer decoding. macOS owns IOSurface
  allocation and AVFoundation decoding. Neither platform's decoder headers belong
  in the public cache interface.
- The macOS output consists of three RGBA8 IOSurfaces imported into Vulkan using
  `VK_EXT_metal_objects`. Vulkan completes its fence before publishing a slot.
  The consumer releases a session/generation/slot/sequence lease after its Metal
  read completes. The renderer cannot overwrite an outstanding lease.
- XPC owns control and IOSurface transfer. AppKit windows and Metal presentation
  remain in the application process. Frame queues are bounded; disconnect stops
  the session. A failed producer is not automatically restarted.
- One connection owns one output pool and one rendering transaction. The start
  request remains retained until renderer teardown so XPC preserves the client's
  importance donation during asynchronous playback. Active process activities
  allow system sleep and are ended on pause/stop. Resize opens a fresh session;
  generation 1 is scoped to that connection, never shared across sessions.
- Sprite particles use the stock shader's non-geometry path. Rope uses one
  instanced strip per original segment. A vertex ID selects its endpoint or
  Bezier subdivision; each invocation evaluates at most one subdivision pair.
  Total work is O(segments × subdivisions), with no CPU-expanded subdivision mesh.
  Uniforms, vertex-to-fragment interface, width/color and lighting expressions
  remain authored shader code. Direct t multiplication may differ from repeated
  addition by floating-point rounding. Subdivision 0...510 fits the original
  geometry stage's 1024-vertex ceiling; unsupported control flow fails compilation.
- Text uses one FreeType Pango map per thread. Asset-font registration and layout
  share the Fontconfig backend on both platforms; the macOS CoreText default is
  not used for scene text.
- Color attachment contents are loaded unless the pass owner explicitly clears
  them. Blend mode alone cannot establish full pixel/channel coverage: partial
  particles and RGB-only draws must preserve previous color and alpha. Discarding
  that data produced tile-sized holes on the Apple GPU. The desktop scene output
  is opaque; self-tests verify alpha as well as RGB image detail and animation.
- Wallpaper Engine assets and workshop packages are read from user paths.
  They are not modified or redistributed. Missing project/assets and shader
  compilation failures are reported through XPC. The upstream parser still has
  permissive paths for some invalid authored resources; logs remain part of review.
- Verification uses real packages in the supplied library, GPU frame comparisons,
  continuous playback and input, plus focused lifecycle tests. A diagnostic source
  is not evidence that a scene played.

Initial backend dependency: MoltenVK 1.4.2 (public API macOS distribution), and the
already pinned DXC commit built natively for arm64. Runtime texture formats and
particle coverage must be verified on the actual M1 Pro.

Runtime settings use a `configure` message with validated JSON (fps, fit, volume,
muted, properties). The same payload may be staged in `start`; defaults and
property conditions come from project.json. `PROPERTY_LOAD_USER_PROPERTIES` is
used before loading, and `PROPERTY_USER_PROPERTIES` for subsequent live changes.
Changing unrelated settings does not re-dispatch unchanged user properties.
The common VividRenderClient/RenderServiceView transport also accepts the web
service's BGRA8 pool; it does not reinterpret channel order as RGBA.
