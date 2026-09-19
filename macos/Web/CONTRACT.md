# macOS CEF host contract

The host is an application-scoped XPC service. `RunLoopType=NSRunLoop` lets
`xpc_main` own the service listener while CEF's external message pump runs on the
main thread, with a `CefAppProtocol` NSApplication subclass. Chromium child
processes use bundled Helper apps; no external AppKit wallpaper helper or
registered launch agent is needed. This route passed a real XPC/GPU probe on M1 Pro / macOS 26.6.2. The
outer .app is configured as Chromium’s main bundle; the framework and helper
paths remain explicit inside the .xpc. Treating .xpc as the outer app makes
Chromium search the helper executable directory for ANGLE libraries.

The application owns desktop NSWindows, configuration and per-display sessions.
The web service reuses the version 1 pool/frame/release/pointer/pause protocol.
Each connection owns one browser and three BGRA8 IOSurfaces; a pool is immutable
for that connection. Resizing creates a new connection. A slot is writable only
after its matching sequence is released. Frames may be dropped when all slots
are leased. Browser load errors and renderer crashes fail the session; there is
no automatic restart loop.

CEF's accelerated-paint IOSurface is valid only during the callback. The host
opens it for each callback, copies into a free owned slot using Metal, and waits
for that copy to complete before returning. Only then does it publish the lease.
Holding the original CEF texture after callback return would violate CEF's
contract, even with CFRetain. No CPU frame copy or disk transport is used.

The service receives connections only through its containing signed application
bundle. It retains the start request for the session's XPC transaction. The app
cancels the connection on teardown; the service closes the browser and releases
its pool after callbacks finish. Chromium subprocesses are closed with their
browser host. The validation run confirmed there were no remaining CEF processes after the
XPC service had exited. Service idle lifetime remains managed by XPC.

Project pages run at their original file URLs. The sole Vivid JS bridge is
included from producer/src/renderers/web/vivid_web_bridge_js.h and injected by
the Chromium renderer before page scripts. User/general properties and paused
state are replayed after navigation. Popups are denied; local project content
must not navigate the management panel. System audio/media capture is not yet
provided and is not advertised. CEF and its resources are pinned and bundled;
no build-time dependency source edits are allowed.

The message pump coalesces work into one dispatch-source timer, keeping the
scheduler bounded. This is a development bundle with ad hoc signatures and
Chromium sandboxing disabled; release hardening and notarization are separate
work. HTML media volume and general-property notifications are implemented;
custom WebAudio gain graphs remain the wallpaper author's responsibility.
