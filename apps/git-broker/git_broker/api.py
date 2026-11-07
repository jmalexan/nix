"""A small machine API; no arbitrary URLs, shell commands, or GitHub API proxy."""

import asyncio
import json
import os
import secrets
import tempfile
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse

from .backend import OID, Backend, BrokerError


class SnapshotResponse(FileResponse):
    async def __call__(self, scope, receive, send):
        try:
            await super().__call__(scope, receive, send)
        finally:
            Path(self.path).unlink(missing_ok=True)


def create_app(backend, client_token, max_bytes=128 * 1024 * 1024, approval_gate=None):
    if len(client_token) < 32 or not client_token.isascii():
        raise ValueError("Invalid broker client credential")
    app = FastAPI(title="Git broker", docs_url=None, redoc_url=None, openapi_url=None)

    def authenticate(request: Request):
        supplied = request.headers.get("authorization", "")
        if not secrets.compare_digest(
            supplied.encode(), ("Bearer " + client_token).encode()
        ):
            raise HTTPException(401, "Invalid broker credential")

    @app.exception_handler(BrokerError)
    async def failed(request, error):
        from fastapi.responses import JSONResponse

        return JSONResponse({"detail": error.message}, status_code=error.status)

    @app.middleware("http")
    async def private(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/v1/repositories", dependencies=[Depends(authenticate)])
    def repositories():
        return {
            alias: repo.model_dump() for alias, repo in backend.repositories.items()
        }

    @app.get("/v1/repositories/{alias}/snapshot", dependencies=[Depends(authenticate)])
    def snapshot(alias: str):
        backend.repo(alias)
        fd, path = tempfile.mkstemp(dir=backend.state, suffix=".bundle")
        os.close(fd)
        destination = Path(path)
        destination.unlink()  # git bundle creates its own output atomically
        try:
            backend.snapshot(alias, destination)
            if destination.stat().st_size > max_bytes:
                raise BrokerError(
                    413, "Repository snapshot exceeds the configured bundle limit"
                )
            print(
                json.dumps({"operation": "snapshot", "repository": alias}), flush=True
            )
            return SnapshotResponse(destination, media_type="application/x-git-bundle")
        except BaseException:
            destination.unlink(missing_ok=True)
            raise

    @app.post("/v1/repositories/{alias}/push", dependencies=[Depends(authenticate)])
    async def push(
        request: Request,
        alias: str,
        branch: str = Query(max_length=200),
        commit: str = Query(pattern=OID),
        expected: str = Query(pattern=OID),
        approval: str = Query(pattern=r"^[A-Za-z0-9_-]{24}$"),
    ):
        repo = backend.repo(alias)
        if approval_gate is None:
            raise HTTPException(503, "Push approval service is required")
        scope = {
            "repository": repo.github,
            "branch": branch,
            "commit": commit,
            "expected": expected,
        }
        length = request.headers.get("content-length", "")
        if not length.isdigit() or request.headers.get("transfer-encoding"):
            raise HTTPException(411, "Content-Length required")
        if not 0 < int(length) <= max_bytes:
            raise HTTPException(413, "Bundle exceeds the configured limit")
        fd, path = tempfile.mkstemp(dir=backend.state, suffix=".bundle")
        try:
            with os.fdopen(fd, "wb") as target:
                size = 0
                try:
                    async with asyncio.timeout(120):
                        async for part in request.stream():
                            size += len(part)
                            if size > max_bytes or size > int(length):
                                raise HTTPException(
                                    413, "Bundle exceeds the configured limit"
                                )
                            target.write(part)
                except TimeoutError:
                    raise HTTPException(408, "Bundle upload timed out") from None
                if size != int(length):
                    raise HTTPException(400, "Incomplete bundle")
            from starlette.concurrency import run_in_threadpool

            claimed = False

            def authorize():
                nonlocal claimed
                deadline = approval_gate.claim(approval, scope)
                claimed = True
                return deadline

            try:
                result = await run_in_threadpool(
                    backend.push,
                    alias,
                    branch,
                    commit,
                    expected,
                    Path(path),
                    authorize=authorize,
                )
            except BaseException:
                if claimed:
                    await run_in_threadpool(approval_gate.finish, approval, "failed")
                raise
            if claimed:
                await run_in_threadpool(approval_gate.finish, approval, "completed")
            print(
                json.dumps({"operation": "push", "repository": alias, **result}),
                flush=True,
            )
            return result
        finally:
            Path(path).unlink(missing_ok=True)

    return app


def from_environment():
    from .approval import Gate

    backend = Backend(
        os.environ["GIT_BROKER_STATE"],
        json.loads(Path(os.environ["GIT_BROKER_REPOSITORIES"]).read_text()),
        Path(os.environ["GIT_BROKER_UPSTREAM_TOKEN"]).read_text().strip(),
    )
    return create_app(
        backend,
        Path(os.environ["GIT_BROKER_CLIENT_TOKEN"]).read_text().strip(),
        int(os.environ.get("GIT_BROKER_MAX_BYTES", str(128 * 1024 * 1024))),
        approval_gate=Gate(
            os.environ["GIT_BROKER_APPROVAL_ORIGIN"],
            Path(os.environ["GIT_BROKER_APPROVAL_TOKEN"]).read_text().strip(),
        ),
    )
