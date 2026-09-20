# macOS panel control

The application starts `vivid_webui_server.py` with inherited stdin/stdout pipes.
The Python standard-library HTTP server binds only `127.0.0.1`, defaults to port
8765, and permits matching local Host/Origin requests. `VIVID_WEBUI_PORT` can
override the port; port 0 is useful for isolated integration checks. There is no
Linux daemon, Unix socket transport, binary protocol or protocol generator.

The backend sends one JSON object per line. A ready event contains the bound URL;
control requests contain `id`, `opcode`, and `payload`. The application replies
with the same `id` and either `ok: true, control: {opcode: 2, payload: snapshot}`
or `ok: false, error: message`. NativeControl converts failed replies into HTTP
errors, and closes HTTP when the parent pipe ends. Diagnostics go to stderr.
Messages are limited to 1 MiB; one control request is outstanding at a time,
and a server lock serializes complete HTTP read/modify/write mutations.

The retained control numbers match `WebUIService.swift`:

| Number | Operation |
| --- | --- |
| 1 | Read state |
| 4 | Set playing |
| 5 | Set muted |
| 6 | Set volume |
| 7 | Set content fit |
| 8 | Set scene FPS |
| 13 | Apply configuration |

HTTP endpoints, configuration keys, project catalog/property interpretation and
the `main.js`/`styles.css`/`index.html` UI retain Vivid's behavior. Capabilities
from the native app decide which controls are offered. The native coordinator
alone persists user configuration and commits playback replacements after their
first frame. See [development rules](../DEVELOPMENT.md) and
[panel validation](../../docs/macos-panel-validation.zh-CN.md).
