import json
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

from sutra.codex_metering import (
    CodexRequestError,
    ResponsesSSEUsageParser,
    completed_responses_usage,
    validate_responses_request,
)


class CodexMeteringTests(unittest.TestCase):
    MODEL = "gpt-6-luna"

    def test_request_route_is_exact_and_output_is_clamped(self):
        request = validate_responses_request(
            json.dumps({"model": self.MODEL, "input": "task", "max_output_tokens": 900}).encode(),
            expected_model=self.MODEL,
            max_input_bytes=4096,
            max_output_tokens=500,
        )
        self.assertEqual(request.model, self.MODEL)
        self.assertEqual(request.max_output_tokens, 500)
        self.assertEqual(json.loads(request.body)["max_output_tokens"], 500)

    def test_rejects_wrong_model_bad_json_oversized_and_malformed_caps(self):
        cases = (
            (b"not json", self.MODEL, 4096, 500),
            (b"[]", self.MODEL, 4096, 500),
            (b'{"model":"other"}', self.MODEL, 4096, 500),
            (json.dumps({"model": self.MODEL, "max_output_tokens": True}).encode(), self.MODEL, 4096, 500),
            (json.dumps({"model": self.MODEL}).encode(), self.MODEL, 2, 500),
        )
        for raw, model, input_limit, output_limit in cases:
            with self.subTest(raw=raw, input_limit=input_limit):
                with self.assertRaises(CodexRequestError):
                    validate_responses_request(
                        raw, expected_model=model, max_input_bytes=input_limit,
                        max_output_tokens=output_limit,
                    )

    def test_untrusted_or_partial_usage_never_counts_as_complete(self):
        for event in (
            None,
            {"type": "response.in_progress", "response": {"usage": {"input_tokens": 4, "output_tokens": 2}}},
            {"type": "response.completed", "response": {"usage": {"input_tokens": True, "output_tokens": 2}}},
            {"type": "response.completed", "response": {"usage": {"input_tokens": 4, "output_tokens": -1}}},
        ):
            with self.subTest(event=event):
                self.assertIsNone(completed_responses_usage(event))

    def test_sse_parser_handles_chunk_boundaries_and_only_completed_usage(self):
        parser = ResponsesSSEUsageParser()
        parser.feed(b'event: response.in_progress\ndata: {"type":"response.in_progress"}\n\n')
        parser.feed(b'event: response.completed\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":12,')
        parser.feed(b'"output_tokens":7}}}\n\n')
        self.assertEqual(parser.finish(), (12, 7))

    def test_sse_parser_does_not_infer_usage_from_truncated_stream(self):
        parser = ResponsesSSEUsageParser()
        parser.feed(b'data: {"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":7}}}')
        # A complete semantic event must be separated by its SSE frame boundary.
        self.assertIsNone(parser.finish())

    def test_proxy_authorizes_and_reconciles_usage_before_returning_provider_result(self):
        from sutra.codex_metering import MeteredResponsesProxy

        event_body = (b'event: response.completed\ndata: {"type":"response.completed",'
                      b'"response":{"usage":{"input_tokens":12,"output_tokens":7}}}\n\n')

        class Store:
            def __init__(self):
                self.events = []

            def codex_start_request(self, *args):
                self.events.append(("authorize", args))
                return {"authorized": True}

            def codex_record_usage(self, *args):
                self.events.append(("usage", args))
                return {"recorded": True}

        class Response:
            status = 200
            headers = {"Content-Type": "text/event-stream"}

            def __init__(self, body):
                self.body = body
                self.offset = 0

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return None

            def read(self, size=-1):
                if self.offset >= len(self.body):
                    return b""
                end = len(self.body) if size < 0 else self.offset + size
                chunk = self.body[self.offset:end]
                self.offset = end
                return chunk

            def close(self):
                return None

        store = Store()
        proxy = MeteredResponsesProxy(
            store, "sutra-worker-abcdefgh", "run-id", "lease-id", self.MODEL,
            1000, 500, "test-provider-key",
        )
        with patch("sutra.codex_metering.open_outbound_request", return_value=Response(event_body)):
            with proxy:
                request = urllib.request.Request(
                    proxy.base_url + "/responses",
                    data=json.dumps({"model": self.MODEL, "input": "task", "stream": True}).encode(),
                    headers={"Content-Type": "application/json", "Authorization": "Bearer client-secret"},
                    method="POST",
                )
                with urllib.request.urlopen(request, timeout=2) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), event_body)
        self.assertEqual([event[0] for event in store.events], ["authorize", "usage"])
        self.assertEqual(store.events[1][1][-2:], (12, 7))

    def test_proxy_rejects_non_streaming_request_before_authorization(self):
        from sutra.codex_metering import MeteredResponsesProxy

        class Store:
            def codex_start_request(self, *args):
                raise AssertionError("invalid request must be rejected before database authorization")

        proxy = MeteredResponsesProxy(
            Store(), "sutra-worker-abcdefgh", "run-id", "lease-id", self.MODEL,
            1000, 500, "test-provider-key",
        )
        with proxy:
            request = urllib.request.Request(
                proxy.base_url + "/responses",
                data=json.dumps({"model": self.MODEL, "input": "task", "stream": False}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with self.assertRaises(urllib.error.HTTPError) as result:
                urllib.request.urlopen(request, timeout=2)
        self.assertEqual(result.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
