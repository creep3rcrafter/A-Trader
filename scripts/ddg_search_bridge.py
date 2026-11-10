"""Search-only stdio MCP adapter; never run the upstream auto/browser transport."""

import asyncio
import importlib.metadata
import json
import sys

SCHEMA = {
    "type": "object",
    "properties": {"query": {"type": "string"}, "max_results": {"type": "integer"}},
    "required": ["query", "max_results"],
    "additionalProperties": False,
}
CATEGORIES = ("company news earnings", "company regulatory filings", "company risks")


def valid_arguments(args):
    if not isinstance(args, dict) or set(args) != {"query", "max_results"}:
        return False
    query = args["query"]
    if not isinstance(query, str) or args["max_results"] != 3:
        return False
    import re

    return any(
        re.fullmatch(r"[A-Z0-9.-]{1,15} " + category, query)
        for category in CATEGORIES
    )


class Context:
    failed = False

    async def info(self, _message):
        pass

    async def error(self, _message):
        self.failed = True


async def search(args):
    import httpx
    from duckduckgo_mcp_server.server import DuckDuckGoSearcher

    class ConservativeSearcher(DuckDuckGoSearcher):
        async def _request(self, data, ctx):
            # Upstream httpx retries 429 and sends Chrome headers. Replace both.
            async with httpx.AsyncClient(
                verify=True, follow_redirects=False, trust_env=False, timeout=12
            ) as client:
                async with client.stream(
                    "POST",
                    "https://html.duckduckgo.com/html",
                    data=data,
                    headers={"User-Agent": "A-Trader-Personal-Research/1.0"},
                ) as response:
                    if response.status_code != 200:
                        ctx.failed = True
                        return ""
                    body = bytearray()
                    async for chunk in response.aiter_bytes():
                        body.extend(chunk)
                        if len(body) > 524288:
                            ctx.failed = True
                            return ""
            html = body.decode("utf-8", errors="replace")
            if not html.strip() or any(
                signal in html.lower()
                for signal in (
                    "captcha", "anomaly.js", "challenge-form", "cf-mitigated",
                    "just a moment", "checking your browser", "enable javascript",
                )
            ):
                ctx.failed = True
                return ""
            return html

    ctx = Context()
    searcher = ConservativeSearcher(backend="httpx", ref_url_threshold=0)
    results = await asyncio.wait_for(
        searcher.search(args["query"], ctx, max_results=3), timeout=15
    )
    if ctx.failed or not results:
        return {"status": "blocked_or_unavailable", "results": []}
    return {
        "status": "ok",
        "results": [
            {"title": r.title[:300], "url": r.link[:2001], "snippet": r.snippet[:600]}
            for r in results[:3]
        ],
    }


def main():
    if importlib.metadata.version("duckduckgo-mcp-server") != "0.7.0":
        raise RuntimeError("Pinned search package is not installed")
    initialized = False
    searched = False
    for _ in range(4):
        raw = sys.stdin.buffer.readline(8193)
        if not raw or len(raw) > 8192:
            return
        message = json.loads(raw)
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params", {})
        if method == "initialize" and not initialized:
            initialized = True
            result = {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "a-trader-search-only", "version": "0.7.0"},
            }
        elif method == "notifications/initialized" and initialized:
            continue
        elif method == "tools/list" and initialized:
            result = {"tools": [{"name": "search", "inputSchema": SCHEMA}]}
        elif (
            method == "tools/call" and initialized and not searched
            and params.get("name") == "search"
            and valid_arguments(params.get("arguments"))
        ):
            searched = True
            try:
                data = asyncio.run(search(params["arguments"]))
            except Exception:
                data = {"status": "blocked_or_unavailable", "results": []}
            result = {"content": [{"type": "text", "text": json.dumps(data)}]}
        else:
            return
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)


if __name__ == "__main__":
    main()
