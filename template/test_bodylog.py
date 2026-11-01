# Run: python test_bodylog.py  (stdlib only)
import asyncio
import contextlib
import io
import json

from bodylog import BodyLog, mask

assert mask('{"user": "a", "password": "hunter2"}') == '{"user": "a", "password": "***"}'
assert mask('{"Token":"abc') == '{"Token":"***"'  # clipped mid-value
assert mask("user=a&password=hunter2&x=1") == "user=a&password=***&x=1"


async def echo(scope, receive, send):
    body = (await receive())["body"]
    await send({"type": "http.response.start", "status": 201, "headers": []})
    await send({"type": "http.response.body", "body": body.upper()})


async def run():
    msgs = iter([{"type": "http.request", "body": b'{"api_key": "k", "v": 1}'}])
    sent = []

    async def receive():
        return next(msgs)

    async def send(msg):
        sent.append(msg)

    scope = {"type": "http", "method": "POST", "path": "/x", "query_string": b"token=t&a=1"}
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        await BodyLog(echo)(scope, receive, send)
    return sent, json.loads(out.getvalue())


sent, line = asyncio.run(run())
assert sent[1]["body"] == b'{"API_KEY": "K", "V": 1}'  # response passes through unchanged
assert line["status"] == 201 and line["query"] == "token=***&a=1"
assert line["received"] == '{"api_key": "***", "v": 1}'
assert line["sent"] == '{"API_KEY": "***", "V": 1}'
print("ok")
