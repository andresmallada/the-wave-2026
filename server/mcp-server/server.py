import os

from fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route
from starlette.types import ASGIApp, Receive, Scope, Send

# ---------------------------------------------------------------------------
# Auth middleware (simple Bearer token check)
# ---------------------------------------------------------------------------
AUTH_TOKEN = os.environ.get("MCP_AUTH_TOKEN")


class BearerAuthMiddleware:
    """Reject requests without a valid Bearer token (skips /health)."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" and scope["type"] != "websocket":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "")
        if path == "/health":
            await self.app(scope, receive, send)
            return

        if AUTH_TOKEN:
            headers = dict(scope.get("headers", []))
            auth_header = headers.get(b"authorization", b"").decode()
            if not auth_header.startswith("Bearer ") or auth_header[7:] != AUTH_TOKEN:
                response = JSONResponse(
                    {"error": "Unauthorized"}, status_code=401
                )
                await response(scope, receive, send)
                return

        await self.app(scope, receive, send)


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------
mcp = FastMCP(
    name="RayBan Meta Agent",
    instructions=(
        "You are an AI agent connected to Meta Ray-Ban smart glasses. "
        "Use the available tools to help the user with real-world tasks."
    ),
)

# ---------------------------------------------------------------------------
# Tools (placeholder — replace with real implementations later)
# ---------------------------------------------------------------------------

@mcp.tool
def web_search(query: str) -> str:
    """Search the web for information and return a summary of results."""
    return f"[placeholder] Search results for: {query}"


@mcp.tool
def send_message(to: str, message: str) -> str:
    """Send a message to a contact via their preferred messaging app."""
    return f"[placeholder] Message sent to {to}: {message}"


@mcp.tool
def add_reminder(text: str, when: str = "later") -> str:
    """Create a reminder for the user at the specified time."""
    return f"[placeholder] Reminder set: '{text}' for {when}"


# ---------------------------------------------------------------------------
# Health check endpoint (mounted alongside FastMCP's ASGI app)
# ---------------------------------------------------------------------------
_fastmcp_app = mcp.http_app()


async def health_check(request: Request):
    return JSONResponse({"status": "ok", "server": "RayBan Meta Agent"})


app = Starlette(
    routes=[
        Route("/health", health_check, methods=["GET"]),
    ],
    lifespan=_fastmcp_app.lifespan,
)

# Mount FastMCP app at root so /mcp is handled by FastMCP
app.mount("/", _fastmcp_app)

# Wrap with Bearer auth middleware
app = BearerAuthMiddleware(app)


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", 3000))
    uvicorn.run(app, host="0.0.0.0", port=port)
