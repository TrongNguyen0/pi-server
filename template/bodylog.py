"""ASGI middleware: logs each request's body and the response's body as one JSON line on stdout.

Works for any data shape (JSON, form, text, binary) without knowing it in advance.
Bodies are clipped to LOG_BODY_MAX bytes and common secret fields are masked.
"""
import json
import os
import re
import time

MAX = int(os.getenv("LOG_BODY_MAX", "2048"))
_KEYS = r"password|passwd|pwd|token|access_token|refresh_token|secret|api_key|apikey|authorization"
# "password": "x"  (value may be cut off by clipping)   |   password=x  (form / query style)
_SECRET = re.compile(rf'("(?:{_KEYS})"\s*:\s*)"[^"]*"?|((?:{_KEYS})=)[^&\s]*', re.I)


def mask(text: str) -> str:
    return _SECRET.sub(lambda m: f'{m[1]}"***"' if m[1] else f"{m[2]}***", text)


def clip(body: bytes) -> str:
    text = body[:MAX].decode("utf-8", "replace")
    return mask(text) + ("...[cut]" if len(body) > MAX else "")


class BodyLog:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        req, res, status, start = bytearray(), bytearray(), 0, time.monotonic()

        async def recv():
            msg = await receive()
            if msg["type"] == "http.request" and len(req) <= MAX:
                req.extend(msg.get("body", b""))
            return msg

        async def snd(msg):
            nonlocal status
            if msg["type"] == "http.response.start":
                status = msg["status"]
            elif msg["type"] == "http.response.body" and len(res) <= MAX:
                res.extend(msg.get("body", b""))
            await send(msg)

        try:
            await self.app(scope, recv, snd)
        finally:
            print(json.dumps({
                "method": scope["method"],
                "path": scope["path"],
                "query": mask(scope.get("query_string", b"").decode("latin-1")),
                "status": status,
                "ms": round((time.monotonic() - start) * 1000, 1),
                "received": clip(bytes(req)),
                "sent": clip(bytes(res)),
            }, ensure_ascii=False), flush=True)
