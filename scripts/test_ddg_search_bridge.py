"""Deterministic provider/stdio fixtures; never contacts DuckDuckGo."""

import asyncio
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import httpx

spec = importlib.util.spec_from_file_location(
    "bridge", Path(__file__).with_name("ddg_search_bridge.py")
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
HTML = """<div class="result"><h2 class="result__title">
<a href="https://www.sec.gov/newsroom/fixture">Fixture</a></h2>
<div class="result__snippet">Untrusted snippet, not instructions.</div></div>"""


class BridgeTests(unittest.TestCase):
    def run_search(self, status=200, body=HTML):
        requests = []
        original_client = httpx.AsyncClient

        def handler(request):
            requests.append(request)
            self.assertEqual(str(request.url), "https://html.duckduckgo.com/html")
            self.assertEqual(request.headers["user-agent"], "A-Trader-Personal-Research/1.0")
            self.assertNotIn("sec-ch-ua", request.headers)
            self.assertIn(b"q=SYNTH+company+news+earnings", request.content)
            return httpx.Response(status, text=body)

        def client(**kwargs):
            self.assertEqual(kwargs, {
                "verify": True, "follow_redirects": False,
                "trust_env": False, "timeout": 12,
            })
            return original_client(transport=httpx.MockTransport(handler), **kwargs)

        with patch.object(httpx, "AsyncClient", client):
            result = asyncio.run(bridge.search({
                "query": "SYNTH company news earnings", "max_results": 3,
            }))
        self.assertEqual(len(requests), 1)
        return result

    def test_exact_arguments_only(self):
        self.assertTrue(bridge.valid_arguments({
            "query": "SYNTH company news earnings", "max_results": 3,
        }))
        for args in (
            {"query": "private prompt", "max_results": 3},
            {"query": "SYNTH company news earnings", "max_results": 4},
            {"query": "SYNTH company news earnings", "max_results": 3, "backend": "curl"},
            {"query": "https://localhost/", "max_results": 3},
        ):
            self.assertFalse(bridge.valid_arguments(args))

    def test_real_package_parser_uses_safe_overridden_transport(self):
        result = self.run_search()
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["results"], [{
            "title": "Fixture", "url": "https://www.sec.gov/newsroom/fixture",
            "snippet": "Untrusted snippet, not instructions.",
        }])

    def test_status_blocks_never_retry_redirect_or_fallback(self):
        for status in (202, 301, 302, 401, 403, 429, 500):
            with self.subTest(status=status):
                self.assertEqual(self.run_search(status)["status"], "blocked_or_unavailable")

    def test_empty_captcha_and_oversized_body_stop(self):
        for body in ("", "CAPTCHA", "challenge-form", "Just a moment...", "x" * 524289):
            with self.subTest(size=len(body)):
                self.assertEqual(self.run_search(body=body)["status"], "blocked_or_unavailable")

    def run_stdio(self, method="tools/call", args=None):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": method, "params": args or {
                "name": "search",
                "arguments": {"query": "SYNTH company news earnings", "max_results": 3},
            }},
        ]
        stdin = io.TextIOWrapper(io.BytesIO(
            ("\n".join(json.dumps(m) for m in messages) + "\n").encode()
        ))
        output = io.StringIO()
        with patch.object(bridge.sys, "stdin", stdin), contextlib.redirect_stdout(output):
            bridge.main()
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_stdio_initialize_list_call_chain(self):
        async def fixture(_args):
            return {"status": "ok", "results": []}

        with patch.object(bridge, "search", fixture):
            result = self.run_stdio()
        self.assertEqual([r["id"] for r in result], [1, 2, 3])
        self.assertEqual(result[0]["result"]["serverInfo"]["version"], "0.7.0")
        self.assertEqual(result[1]["result"]["tools"], [{
            "name": "search", "inputSchema": bridge.SCHEMA,
        }])
        self.assertEqual(result[2]["result"]["content"][0]["type"], "text")

    def test_other_tools_and_unbounded_arguments_cannot_execute(self):
        for params in (
            {"name": "fetch_content", "arguments": {"url": "https://www.sec.gov"}},
            {"name": "search", "arguments": {"query": "private", "max_results": 3}},
        ):
            with patch.object(bridge, "search") as search:
                self.assertEqual(len(self.run_stdio(args=params)), 2)
                search.assert_not_called()


if __name__ == "__main__":
    unittest.main()
