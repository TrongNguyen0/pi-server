import os

from fastapi import FastAPI

from bodylog import BodyLog

app = FastAPI(title="__NAME__")
if os.getenv("LOG_BODY") == "1":
    app.add_middleware(BodyLog)


@app.get("/")
def root():
    return {"project": "__NAME__", "status": "ok"}


@app.post("/echo")
async def echo(data: dict):
    return {"received": data}
