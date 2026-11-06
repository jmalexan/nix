"""HTTP defaults reused by independently hosted micro apps."""

from urllib.parse import urlparse

from fastapi import FastAPI, Request, Response


def create_service(title: str, origin: str) -> FastAPI:
    app = FastAPI(title=title, version="0.1.0")

    @app.middleware("http")
    async def boundary(request: Request, call_next):
        if request.method == "POST" and (
            not request.headers.get("content-length", "").isdigit()
            or request.headers.get("transfer-encoding")
        ):
            return Response("Content-Length required", status_code=411)
        if request.headers.get("host") != urlparse(origin).netloc:
            return Response("Unexpected host", status_code=400)
        if (
            request.headers.get("content-length", "0").isdigit()
            and int(request.headers.get("content-length", "0")) > 32768
        ):
            return Response("Request too large", status_code=413)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        )
        return response

    return app
