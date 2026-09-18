# macOS Development Rules

The approved architecture is recorded in
[the port proposal](../docs/macos-port-proposal.zh-CN.md). P0 probes establish
evidence; they must not become production implementations without contract review.

- Target arm64 and macOS 26+. Use Swift 6 strict concurrency. Treat warnings in
  our Swift and Objective-C++ targets as errors; keep upstream warnings separate.
- AppKit ownership, screen reconciliation and UI state belong to MainActor.
  GPU callbacks run on Metal queues. Mark callbacks `@Sendable` and explicitly
  hop to the owner before updating state. Avoid unchecked Sendable conformances.
- Reuse Vivid's scene parser, script semantics and material behavior. Never
  disable a GPU requirement without implementing and validating its behavior.
- Frame ownership is identified by connection/session, generation, slot and
  sequence. Publish only after GPU completion; release only after the reader
  completes. A timeout or GPU failure never grants permission to reuse a slot.
- Use RAII/ARC for textures, IOSurfaces and XPC objects. Keep queues bounded and
  teardown explicit. No frame-loop file loading, error retries or silent fallback.
- Change the implementation responsible for a failure. Document evidence and
  update the relevant contract instead of adding downstream correction paths.
- Scene core changes are committed directly in this repository. Preserve its
  upstream provenance and license, and keep third-party library revisions pinned
  in the root submodule entries. Never patch dependency sources during builds.
- Keep the P0 static-image source separate from scene compatibility. All runtime
  claims must name the tested hardware, content and lifecycle cases.

Format only files in scope:

```sh
xcrun swift-format format -i -r macos/Sources macos/Package.swift
clang-format -i macos/Probes/FrameTransport/*.hpp macos/Probes/FrameTransport/*.mm
```

Run the build and verification commands in [README.md](README.md). The desktop
probe exercises the real Metal completion callback, including Swift's runtime
actor checks; compile-time checks and offscreen image tests alone do not cover it.
Run Linux compatibility checks when shared renderer behavior changes.
