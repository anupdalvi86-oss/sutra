"""Strict parsing helpers for the metered Codex Responses API gateway.

Codex traffic is streamed. Usage is accepted only from a completed Responses API
event; partial/error streams are intentionally left unsettled so the caller can
mark the reservation unknown and retain its reserve.
"""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .runtime import IntegrationError, open_outbound_request


class CodexRequestError(ValueError):
    """A Codex request cannot be safely admitted by the metering gateway."""


@dataclass(frozen=True)
class ResponsesRequest:
    body: bytes
    model: str
    max_output_tokens: int


def validate_responses_request(raw: bytes, *, expected_model: str,
                               max_input_bytes: int,
                               max_output_tokens: int) -> ResponsesRequest:
    """Validate and clamp a single Responses request to its DB reservation."""
    if (not isinstance(raw, bytes) or not raw or not isinstance(expected_model, str)
            or not expected_model.strip() or isinstance(max_input_bytes, bool)
            or not isinstance(max_input_bytes, int) or max_input_bytes < 1
            or isinstance(max_output_tokens, bool) or not isinstance(max_output_tokens, int)
            or max_output_tokens < 1 or len(raw) > max_input_bytes):
        raise CodexRequestError("request exceeds the approved input reservation")
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise CodexRequestError("request body must be valid JSON") from exc
    if not isinstance(payload, dict):
        raise CodexRequestError("request body must be a JSON object")
    model = payload.get("model")
    if model != expected_model:
        raise CodexRequestError("request model does not match the approved route")
    requested_output = payload.get("max_output_tokens", max_output_tokens)
    if (isinstance(requested_output, bool) or not isinstance(requested_output, int)
            or requested_output < 1):
        raise CodexRequestError("request output token limit is invalid")
    payload["max_output_tokens"] = min(requested_output, max_output_tokens)
    try:
        bounded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False,
                             allow_nan=False).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise CodexRequestError("request body contains unsupported values") from exc
    if len(bounded) > max_input_bytes:
        raise CodexRequestError("bounded request exceeds the approved input reservation")
    return ResponsesRequest(bounded, expected_model, payload["max_output_tokens"])


def completed_responses_usage(event: dict[str, Any]) -> tuple[int, int] | None:
    """Return trusted-shape usage only for a completed Responses event."""
    if not isinstance(event, dict) or event.get("type") != "response.completed":
        return None
    response = event.get("response")
    usage = response.get("usage") if isinstance(response, dict) else None
    if not isinstance(usage, dict):
        return None
    input_tokens = usage.get("input_tokens")
    output_tokens = usage.get("output_tokens")
    if (isinstance(input_tokens, bool) or not isinstance(input_tokens, int) or input_tokens < 0
            or isinstance(output_tokens, bool) or not isinstance(output_tokens, int)
            or output_tokens < 0):
        return None
    return input_tokens, output_tokens


class ResponsesSSEUsageParser:
    """Incrementally parse SSE frames without retaining generated content."""

    def __init__(self) -> None:
        self._buffer = bytearray()
        self.usage: tuple[int, int] | None = None
        self.completed = False
        self.failed = False

    def feed(self, chunk: bytes) -> list[tuple[bytes, tuple[int, int] | None]]:
        if not isinstance(chunk, bytes):
            raise TypeError("SSE chunk must be bytes")
        self._buffer.extend(chunk)
        frames: list[tuple[bytes, tuple[int, int] | None]] = []
        while True:
            boundary = self._buffer.find(b"\n\n")
            separator_size = 2
            if boundary < 0:
                boundary = self._buffer.find(b"\r\n\r\n")
                separator_size = 4
            if boundary < 0:
                return frames
            frame = bytes(self._buffer[:boundary])
            full_frame = bytes(self._buffer[:boundary + separator_size])
            del self._buffer[:boundary + separator_size]
            frames.append((full_frame, self._consume_frame(frame)))

    def finish(self) -> tuple[int, int] | None:
        # Only a blank-line terminated SSE frame is complete. Never count a
        # truncated response body as provider usage.
        self._buffer.clear()
        return self.usage if self.completed else None

    def _consume_frame(self, frame: bytes) -> tuple[int, int] | None:
        data_lines = []
        for line in frame.replace(b"\r\n", b"\n").split(b"\n"):
            if line.startswith(b"data:"):
                data_lines.append(line[5:].lstrip())
        if not data_lines:
            return None
        data = b"\n".join(data_lines)
        if data == b"[DONE]":
            return None
        try:
            event = json.loads(data)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None
        if isinstance(event, dict) and event.get("type") in {"error", "response.failed", "response.incomplete"}:
            self.failed = True
        usage = completed_responses_usage(event)
        if usage is not None:
            self.usage = usage
            self.completed = True
        return usage


class MeteredResponsesProxy:
    """Loopback-only Responses API proxy gated by the live Codex DB reservation.

    The complete stream is buffered (within a strict ceiling), usage is written
    to Supabase, and only then is the response returned to Codex. A missing or
    malformed completed event fails closed so the outer runner can retain the
    reservation as unknown.
    """

    def __init__(self, store: Any, worker_id: str, run_id: str, lease_token: str,
                 model: str, max_input_tokens: int, max_output_tokens: int,
                 api_key: str, host: str = "127.0.0.1", port: int = 0,
                 max_response_bytes: int = 16_000_000):
        for name, value in (("worker_id", worker_id), ("run_id", run_id),
                            ("lease_token", lease_token), ("model", model),
                            ("api_key", api_key)):
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{name} is required")
        if (isinstance(max_input_tokens, bool) or not isinstance(max_input_tokens, int)
                or max_input_tokens < 1 or isinstance(max_output_tokens, bool)
                or not isinstance(max_output_tokens, int) or max_output_tokens < 1
                or isinstance(port, bool) or not isinstance(port, int) or not 0 <= port <= 65535
                or max_response_bytes < 1024):
            raise ValueError("invalid Codex proxy limits")
        if host not in {"127.0.0.1", "::1", "localhost"}:
            raise ValueError("Codex metering proxy must bind to loopback")
        self.store = store
        self.worker_id = worker_id
        self.run_id = run_id
        self.lease_token = lease_token
        self.model = model
        self.max_input_tokens = max_input_tokens
        self.max_output_tokens = max_output_tokens
        self.api_key = api_key
        self.host = host
        self.port = port
        self.max_response_bytes = max_response_bytes
        self.saw_usage = False
        self.uncertain = False
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def base_url(self) -> str:
        if self._server is None:
            raise RuntimeError("Codex proxy is not running")
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}/v1"

    def __enter__(self) -> "MeteredResponsesProxy":
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
                proxy._handle(self)

            def log_message(self, fmt: str, *args: Any) -> None:
                # Requests can contain private source and credentials; log no body/URL.
                return

        self._server = ThreadingHTTPServer((self.host, self.port), Handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True,
                                        name="sutra-codex-metering-proxy")
        self._thread.start()
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self._server:
            self._server.shutdown()
            self._server.server_close()
        if self._thread:
            self._thread.join(timeout=2)
        self._server = None
        self._thread = None

    def _json_error(self, handler: BaseHTTPRequestHandler, status: int, code: str) -> None:
        body = json.dumps({"error": {"type": "sutra_policy_error", "code": code}}).encode()
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.wfile.write(body)
        handler.close_connection = True

    def _handle(self, handler: BaseHTTPRequestHandler) -> None:
        if handler.path != "/v1/responses":
            self._json_error(handler, 404, "unsupported_endpoint")
            return
        content_length = handler.headers.get("Content-Length", "")
        max_input_bytes = min(self.max_input_tokens * 8, 2_000_000)
        if not content_length.isdigit() or not 0 < int(content_length) <= max_input_bytes:
            self._json_error(handler, 413, "request_size_exceeds_reservation")
            return
        try:
            raw = handler.rfile.read(int(content_length))
            if len(raw) != int(content_length):
                raise CodexRequestError("truncated request body")
            bounded = validate_responses_request(
                raw,
                expected_model=self.model,
                max_input_bytes=max_input_bytes,
                max_output_tokens=self.max_output_tokens,
            )
            request = json.loads(bounded.body)
            if request.get("stream") is not True:
                raise CodexRequestError("Codex Responses requests must be streamed")
            authorized = self.store.codex_start_request(
                self.worker_id, self.run_id, self.lease_token, self.model,
                bounded.max_output_tokens, len(bounded.body),
            )
            if not isinstance(authorized, dict) or authorized.get("authorized") is not True:
                self._json_error(handler, 403, "codex_request_not_authorized")
                return
        except CodexRequestError:
            self._json_error(handler, 400, "invalid_codex_request")
            return
        except IntegrationError:
            self._json_error(handler, 503, "policy_service_unavailable")
            return

        upstream = urllib.request.Request(
            "https://api.openai.com/v1/responses",
            data=bounded.body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
                "User-Agent": "sutra-codex-metered-runner",
            },
        )
        try:
            response = open_outbound_request(upstream, timeout=600)
            status = response.status
            content_type = response.headers.get("Content-Type", "")
        except urllib.error.HTTPError as exc:
            # Provider error details may include task material. Do not persist or
            # relay those details into logs or GitHub output.
            self.uncertain = True
            self._json_error(handler, 502, "model_provider_rejected_request")
            return
        except (urllib.error.URLError, TimeoutError, OSError):
            self.uncertain = True
            self._json_error(handler, 502, "model_provider_unreachable")
            return
        if status < 200 or status >= 300:
            response.close()
            self.uncertain = True
            self._json_error(handler, 502, "model_provider_request_failed")
            return
        if "text/event-stream" not in content_type.lower():
            response.close()
            self.uncertain = True
            self._json_error(handler, 502, "model_response_not_streamed")
            return

        parser = ResponsesSSEUsageParser()
        handler.send_response(200)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Connection", "close")
        handler.end_headers()
        response_bytes = 0
        try:
            while chunk := response.read(8192):
                response_bytes += len(chunk)
                if response_bytes > self.max_response_bytes:
                    self.uncertain = True
                    handler.close_connection = True
                    return
                for frame, usage in parser.feed(chunk):
                    if usage is not None:
                        recorded = self.store.codex_record_usage(
                            self.worker_id, self.run_id, self.lease_token, usage[0], usage[1],
                        )
                        if not isinstance(recorded, dict) or recorded.get("recorded") is not True:
                            self.uncertain = True
                            handler.close_connection = True
                            return
                        self.saw_usage = True
                    if parser.failed:
                        self.uncertain = True
                    handler.wfile.write(frame)
                    handler.wfile.flush()
            if parser.finish() is None or parser.failed:
                self.uncertain = True
            handler.close_connection = True
        except (IntegrationError, OSError, TimeoutError):
            # A provider request was already accepted. If usage or transport
            # settlement fails, let the Codex client see a truncated stream and
            # retain the database reserve as unknown.
            self.uncertain = True
            handler.close_connection = True
        finally:
            response.close()
