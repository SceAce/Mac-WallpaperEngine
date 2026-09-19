"""Private, inherited-pipe transport used by the macOS application.

Only HTTP listens on loopback. Native control has no discoverable socket/port.
One request at a time prevents concurrent WebUI read/modify/write operations.
"""
import json
import sys
import threading

MAX_MESSAGE_BYTES = 1024 * 1024


class NativeControl:
    def __init__(self, on_disconnect):
        self._lock = threading.Lock()
        self._condition = threading.Condition()
        self._response = None
        self._closed = False
        self._next_id = 0
        self._on_disconnect = on_disconnect
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    @staticmethod
    def send(value):
        data = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(data) > MAX_MESSAGE_BYTES:
            raise ValueError("native message exceeds 1 MiB")
        sys.stdout.buffer.write(data + b"\n")
        sys.stdout.buffer.flush()

    def _read(self):
        try:
            while True:
                line = sys.stdin.buffer.readline(MAX_MESSAGE_BYTES + 2)
                if not line:
                    break
                if len(line) > MAX_MESSAGE_BYTES + 1 or not line.endswith(b"\n"):
                    break
                response = json.loads(line)
                with self._condition:
                    self._response = response
                    self._condition.notify_all()
        finally:
            with self._condition:
                self._closed = True
                self._condition.notify_all()
            self._on_disconnect()

    def __call__(self, opcode, payload=None):
        with self._lock:
            with self._condition:
                if self._closed:
                    raise ConnectionError("Vivid has exited")
                self._next_id += 1
                request_id = self._next_id
                self._response = None
                self.send({"id": request_id, "opcode": opcode, "payload": payload or {}})
                received = self._condition.wait_for(
                    lambda: self._closed or (self._response is not None and self._response.get("id") == request_id),
                    timeout=40,
                )
                if not received:
                    raise TimeoutError("Vivid did not complete the change within 40 seconds")
                if self._closed:
                    raise ConnectionError("Vivid has exited")
                response = self._response
                if not response.get("ok"):
                    raise ValueError(response.get("error", "Native control failed"))
                return response["control"]
