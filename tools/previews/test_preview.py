import asyncio
import time

from aiohttp import ClientSession, WSMsgType, web
from preview import DOMAIN, FIRST_PORT, SLOTS, load, router, save, target


def test_registry_rejects_unknown_expired_and_out_of_range(tmp_path):
    record = {"port": FIRST_PORT, "expires": 200}
    records = {"one": record}
    assert target(f"one.{DOMAIN}", records, now=100) == f"http://127.0.0.1:{FIRST_PORT}"
    assert target(f"one.{DOMAIN}", records, now=200) is None
    assert target(f"two.{DOMAIN}", records, now=100) is None
    assert target("approve.nasa.jmalexan.com", records, now=100) is None
    for port in (22, FIRST_PORT + SLOTS, "18100", True):
        record["port"] = port
        assert target(f"one.{DOMAIN}", records, now=100) is None
    save(records, tmp_path)
    assert load(tmp_path) == records


def test_concurrent_http_cookie_isolation_and_websocket(tmp_path):
    async def run():
        async def handler(request):
            if request.path == "/socket":
                ws = web.WebSocketResponse(protocols=["vite-hmr"])
                await ws.prepare(request)
                async for message in ws:
                    if message.type == WSMsgType.TEXT:
                        await ws.send_str(message.data)
                return ws
            if request.method == "POST":
                assert request.headers.get("Content-Length") == "7"
                assert "Transfer-Encoding" not in request.headers
            response = web.json_response(
                {
                    "host": request.host,
                    "path": request.raw_path,
                    "body": await request.text(),
                    "proto": request.headers.get("X-Forwarded-Proto"),
                }
            )
            response.set_cookie("session", "sample", secure=True, httponly=True)
            return response

        runners = []
        try:
            for port in (FIRST_PORT, FIRST_PORT + 1):
                backend = web.Application()
                backend.router.add_route("*", "/{path:.*}", handler)
                runner = web.AppRunner(backend)
                await runner.setup()
                runners.append(runner)
                await web.TCPSite(runner, "127.0.0.1", port).start()
            records = {
                name: {"port": FIRST_PORT + i, "expires": time.time() + 60}
                for i, name in enumerate(("one", "two"))
            }
            save(records, tmp_path)
            gateway = web.AppRunner(router(tmp_path))
            await gateway.setup()
            runners.append(gateway)
            site = web.TCPSite(gateway, "127.0.0.1", 0)
            await site.start()
            port = site._server.sockets[0].getsockname()[1]
            base = f"http://127.0.0.1:{port}"
            async with ClientSession() as client:
                for name in ("one", "two"):
                    host = f"{name}.{DOMAIN}"
                    async with client.post(
                        base + "/api/test?q=%2F", data="payload", headers={"Host": host}
                    ) as response:
                        assert response.status == 200
                        assert await response.json() == {
                            "host": host,
                            "path": "/api/test?q=/",
                            "body": "payload",
                            "proto": "https",
                        }
                        assert "Domain=" not in response.headers["Set-Cookie"]
                        assert response.headers["Cache-Control"] == "no-store"
                    async with client.ws_connect(
                        base + "/socket", headers={"Host": host}, protocols=["vite-hmr"]
                    ) as ws:
                        await ws.send_str("update")
                        assert (await ws.receive()).data == "update"
                async with client.get(
                    base, headers={"Host": "missing." + DOMAIN}
                ) as response:
                    assert response.status == 404
                records["one"]["expires"] = 0
                save(records, tmp_path)
                async with client.get(
                    base, headers={"Host": "one." + DOMAIN}
                ) as response:
                    assert response.status == 404
                async with client.get(
                    base, headers={"Host": "two." + DOMAIN}
                ) as response:
                    assert response.status == 200
        finally:
            for runner in reversed(runners):
                await runner.cleanup()

    asyncio.run(run())


def test_html_reload_and_expiry(tmp_path):
    async def run():
        backend = web.Application()
        backend.router.add_get(
            "/",
            lambda request: web.Response(
                text="<html><head></head><body>Preview</body></html>",
                content_type="text/html",
            ),
        )
        runner = web.AppRunner(backend)
        gateway = web.AppRunner(router(tmp_path))
        try:
            await runner.setup()
            await web.TCPSite(runner, "127.0.0.1", FIRST_PORT).start()
            records = {
                "reload": {
                    "port": FIRST_PORT,
                    "expires": time.time() + 60,
                    "version": 1,
                }
            }
            save(records, tmp_path)
            await gateway.setup()
            site = web.TCPSite(gateway, "127.0.0.1", 0)
            await site.start()
            base = f"http://127.0.0.1:{site._server.sockets[0].getsockname()[1]}"
            async with ClientSession(headers={"Host": "reload." + DOMAIN}) as client:
                async with client.get(base) as response:
                    assert response.status == 200
                    assert "/_preview/reload.js" in await response.text()
                async with client.get(base + "/_preview/version") as response:
                    assert await response.json() == {"version": 1}
                records["reload"]["version"] = 2
                save(records, tmp_path)
                async with client.get(base + "/_preview/version") as response:
                    assert await response.json() == {"version": 2}
                records["reload"]["expires"] = 0
                save(records, tmp_path)
                async with client.get(base + "/_preview/version") as response:
                    assert response.status == 404
        finally:
            await gateway.cleanup()
            await runner.cleanup()

    asyncio.run(run())


def test_cleanup_retains_data_when_stop_fails(tmp_path, monkeypatch):
    from types import SimpleNamespace

    import preview
    import pytest

    monkeypatch.setattr(preview, "STATE", tmp_path)
    monkeypatch.setattr(
        preview.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=1)
    )
    monkeypatch.setattr(preview, "active", lambda name: True)
    records = {"one": {"expires": 0}}
    (tmp_path / "one").mkdir()
    with pytest.raises(RuntimeError, match="Could not stop"):
        preview.clean(records)
    assert "one" in records and (tmp_path / "one").is_dir()
    monkeypatch.setattr(preview, "active", lambda name: False)
    preview.clean(records)
    assert records == {} and not (tmp_path / "one").exists()
