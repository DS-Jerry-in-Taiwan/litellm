"""
server.py — Class-based A2A server integration entrypoint.

This module provides the official server entrypoint for the a2a_adapter.
It uses class injection to replace OpencodeUpstreamClient with
PatchedOpencodeUpstreamClient before calling the upstream create_app(),
eliminating the need for runtime method monkey-patching.

Usage:
    from a2a_adapter.server import main
    main()  # blocking — runs uvicorn

Or programmatically:
    from a2a_adapter.server import create_app
    from opencode_a2a.config import Settings
    app = create_app(Settings())

The create_app() function:
1. Injects PatchedOpencodeUpstreamClient into the upstream application module
2. Calls the original opencode-a2a create_app(Settings) to build the FastAPI app
3. Returns the app with app.state.upstream_client being a PatchedOpencodeUpstreamClient

For backwards compatibility, start_patched.py re-exports main() from this module.
"""

from __future__ import annotations

import logging
from typing import cast

import uvicorn
from pydantic_settings import BaseSettings
from starlette.types import ASGIApp, Receive, Scope, Send

from a2a_adapter.client import PatchedOpencodeUpstreamClient
from opencode_a2a.config import Settings
from opencode_a2a.server import application as upstream_application

logger = logging.getLogger(__name__)


def inject_upstream_client_class() -> None:
    """
    Inject PatchedOpencodeUpstreamClient into the upstream application module.

    This replaces the OpencodeUpstreamClient reference in the
    opencode_a2a.server.application module with our subclass before
    create_app() is called. All instances created inside create_app() will
    therefore be PatchedOpencodeUpstreamClient instances.
    """
    upstream_application.OpencodeUpstreamClient = PatchedOpencodeUpstreamClient
    logger.info(
        "Injected PatchedOpencodeUpstreamClient into "
        "opencode_a2a.server.application.OpencodeUpstreamClient"
    )


def _patch_handle_requests(app) -> None:
    """
    Patch the Starlette route for POST / to unwrap ``result.task`` → ``result``,
    convert protobuf enums to LiteLLM format, and stringify the request id
    so LiteLLM's A2A SDK can parse the response.

    NOTE: Simply patching target.endpoint does NOT work because the Route
    also stores target.app = request_response(endpoint) at construction time.
    When the route handles a request it calls self.app (the original), not
    self.endpoint (what we patched). We must patch target.app instead.
    """
    import json as _json

    target = None
    for route in app.routes:
        if route.path == "/" and "POST" in (getattr(route, "methods", None) or {"POST"}):
            target = route
            break

    if target is None:
        logger.warning("Could not find route for POST / — response patch NOT applied")
        return

    _orig_app = target.app

    async def _patched_app(scope, receive, send):
        # Intercept ASGI response events, unwrap result.task → result,
        # and convert protobuf enum values to LiteLLM format.
        from starlette.responses import StreamingResponse
        status_code = 200
        headers = []
        body_chunks = []
        response_started = False

        async def _patched_send(message):
            nonlocal status_code, headers, response_started
            if message["type"] == "http.response.start":
                status_code = message["status"]
                headers = list(message.get("headers", []))
                response_started = True
            elif message["type"] == "http.response.body":
                body_chunks.append(message.get("body", b""))

        await _orig_app(scope, receive, _patched_send)

        if not response_started:
            return

        full_body = b"".join(body_chunks)
        modified = False
        try:
            resp_data = _json.loads(full_body)
            if isinstance(resp_data, dict):
                result = resp_data.get("result")
                if isinstance(result, dict):
                    # 1. Unwrap {"result": {"task": {...}}} → {"result": {...}}
                    task = result.pop("task", None)
                    if isinstance(task, dict):
                        result.update(task)
                        modified = True
                    msg = result.pop("message", None)
                    if isinstance(msg, dict):
                        result.update(msg)
                        modified = True
                    # 2. Inject contextId if missing
                    if "contextId" not in result:
                        result["contextId"] = result.get("id", "")

                    # 3. Ensure id is string (LiteLLM's model requires str)
                    if "id" in resp_data and not isinstance(resp_data["id"], str):
                        resp_data["id"] = str(resp_data["id"])

                    # 4. Convert protobuf enum values to LiteLLM format
                    import re as _re

                    def _convert_enums(obj):
                        """Recursively convert protobuf-style enums to LiteLLM format."""
                        if isinstance(obj, dict):
                            # Convert status.state: "TASK_STATE_COMPLETED" → "completed"
                            if "state" in obj and isinstance(obj["state"], str) and obj["state"].startswith("TASK_STATE_"):
                                obj["state"] = obj["state"][11:].lower().replace("_", "-")
                                # Special case: TASK_STATE_CANCELED → canceled
                                # (protobuf has CANCELED, not CANCELLED - already correct)
                            # Convert role: "ROLE_USER" → "user", "ROLE_AGENT" → "agent"
                            if "role" in obj and isinstance(obj["role"], str) and obj["role"].startswith("ROLE_"):
                                obj["role"] = obj["role"][5:].lower()
                            # Recurse into values
                            for v in obj.values():
                                _convert_enums(v)
                        elif isinstance(obj, list):
                            for item in obj:
                                _convert_enums(item)

                    _convert_enums(resp_data)

        except Exception:
            pass  # Not JSON — forward original unchanged

        if modified:
            patched_body = _json.dumps(resp_data).encode()
            # headers is list of (bytes, bytes) — filter out content-length
            new_headers_list = [(k, v) for k, v in headers if k.lower() != b"content-length"]
            # Build a proper dict for Response (expects str keys/vals)
            new_headers = {k.decode("latin-1"): v.decode("latin-1") for k, v in new_headers_list}
            from starlette.responses import Response as _SR
            new_response = _SR(
                content=patched_body,
                status_code=status_code,
                headers=new_headers,
                media_type="application/json",
            )
            await new_response(scope, receive, send)
            logger.debug("Patched LiteLLM response (unwrapped result.task + converted enums)")
        else:
            # Replay original response
            orig_headers = {k.decode("latin-1"): v.decode("latin-1") for k, v in headers}
            from starlette.responses import Response as _SR
            orig_response = _SR(
                content=full_body,
                status_code=status_code,
                headers=orig_headers,
            )
            await orig_response(scope, receive, send)

    target.app = _patched_app
    logger.info("Patched route POST / app for LiteLLM response format compatibility")


def create_app(settings: Settings):
    """
    Build the A2A FastAPI app with PatchedOpencodeUpstreamClient injected.

    This function:
    1. Calls inject_upstream_client_class() to swap the upstream client class
    2. Calls _patch_response_builder() to fix LiteLLM response format
    3. Delegates to the original opencode-a2a create_app(settings)
    4. Returns the resulting FastAPI app

    After this call, app.state.upstream_client will be a
    PatchedOpencodeUpstreamClient instance.

    Args:
        settings: opencode-a2a Settings object (or compatible pydantic BaseSettings)

    Returns:
        FastAPI application instance
    """
    inject_upstream_client_class()
    app = upstream_application.create_app(settings)
    logger.info(
        "create_app() returned FastAPI app with upstream_client type: %s",
        type(app.state.upstream_client).__name__,
    )

    # -------------------------------------------------------------------------
    # Middleware: translate LiteLLM A2A "message/send" → opencode-a2a "SendMessage"
    #
    # OPENCODE-A2A DISPATCHER uses protobuf ParseDict internally, NOT Pydantic.
    # Protobuf has three key differences from the A2A SDK's Pydantic models:
    #
    #   1. Role → numeric enum:  1 = user, 2 = agent
    #      (A2A SDK sends string "user"/"agent" which protobuf rejects)
    #
    #   2. Part → protobuf oneof (field-presence based), NO discriminator field
    #      A2A SDK sends {"kind": "text", "text": "..."} which has "kind".
    #      Protobuf Part has no "kind"/"type" field at all.
    #      Correct for protobuf: {"text": "..."}
    #
    #   3. Message → protobuf has no "kind" field either
    #      A2A SDK sends {"kind": "message", "messageId": "...", ...}
    #      The "kind" field must be removed.
    #
    # Additionally, LiteLLM's A2A integration sends JSON-RPC requests with
    # method="message/send" but opencode-a2a's dispatcher only handles "SendMessage".
    #
    # This middleware handles all conversions before the request reaches the
    # dispatcher.
    # -------------------------------------------------------------------------
    @app.middleware("http")
    async def translate_a2a_method_alias(request: Request, call_next):
        import json
        import logging

        logger = logging.getLogger("a2a_adapter.middleware")

        # Role mapping: string → protobuf numeric enum
        _ROLE_MAP = {"user": 1, "agent": 2}

        # Fields that MUST be stripped from protobuf-bound dicts because
        # protobuf ParseDict rejects unknown fields.
        _PROTOBUF_DISCRIMINATORS = {"type", "kind"}

        def _strip_protobuf_unknown(obj: dict) -> dict:
            """Remove fields not present in protobuf (discriminators like 'kind', 'type')."""
            return {k: v for k, v in obj.items() if k not in _PROTOBUF_DISCRIMINATORS}

        def _sanitize_parts(parts: list) -> list:
            """Strip protobuf-incompatible fields from every part."""
            return [_strip_protobuf_unknown(p) if isinstance(p, dict) else p for p in parts]

        def _normalise_role(role_val) -> int | str:
            """Convert string role to protobuf numeric enum; leave numeric as-is."""
            if isinstance(role_val, str):
                return _ROLE_MAP.get(role_val, role_val)
            return role_val

        def _translate_body(obj: dict) -> bool:
            """Translate a single JSON-RPC request body. Returns True if modified."""
            if obj.get("method") != "message/send":
                return False

            obj["method"] = "SendMessage"
            params = obj.get("params", {})
            if isinstance(params, dict):
                msg = params.get("message", {})
                if isinstance(msg, dict):
                    # Remove Message-level discriminators (e.g. "kind": "message")
                    # which protobuf does not accept.
                    for _key in list(msg.keys()):
                        if _key in _PROTOBUF_DISCRIMINATORS:
                            del msg[_key]
                    # Convert role string → numeric enum
                    if "role" in msg:
                        msg["role"] = _normalise_role(msg["role"])
                    # Strip part-level discriminators ("kind", "type") from each part
                    parts = msg.get("parts")
                    if isinstance(parts, list):
                        msg["parts"] = _sanitize_parts(parts)
                else:
                    logger.warning("message field is not a dict: %r", type(msg))
            else:
                logger.warning("params field is not a dict: %r", type(params))
            return True

        if request.method == "POST" and request.url.path == "/":
            raw_body = await request.body()
            try:
                data = json.loads(raw_body)
                translated = False

                if isinstance(data, dict):
                    translated = _translate_body(data)
                elif isinstance(data, list):
                    for item in data:
                        if isinstance(item, dict):
                            translated = _translate_body(item) or translated

                if translated:
                    modified_body = json.dumps(data).encode()
                    logger.debug("Translated body: %s", modified_body.decode())
                    # Set the cached body so downstream handlers
                    # (which use the same request object) get our modified body.
                    # Starlette's Request.body() checks hasattr(self, "_body")
                    # and returns the cached value if present.
                    request._body = modified_body
                    # Also clear any cached JSON parsing result so
                    # request.json() re-parses from the modified body.
                    request._json = None
            except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
                pass  # Not valid JSON — let downstream handle it

        return await call_next(request)

    # Add /.well-known/agent.json route (A2A spec standard path).
    # LiteLLM A2A integration fetches this path; opencode-a2a only serves
    # /.well-known/agent-card.json. We serve the same agent card at both paths,
    # with an added 'url' field required by the LiteLLM A2A integration.
    from a2a.server.request_handlers.response_helpers import agent_card_to_dict
    from starlette.responses import JSONResponse as StarletteJSONResponse

    _agent_json_route = None
    public_url = str(settings.a2a_public_url)
    for route in app.routes:
        if route.path == "/.well-known/agent-card.json":
            original_endpoint = route.endpoint

            async def _agent_json_route(_ep=original_endpoint, _url=public_url):
                response = await _ep()
                # LiteLLM A2A requires a top-level 'url' field in the agent card.
                # opencode-a2a doesn't include it, so we inject it here.
                card = response.body
                if isinstance(card, bytes):
                    card = card.decode("utf-8")
                import json as _json
                card_data = _json.loads(card)
                if "url" not in card_data:
                    card_data["url"] = _url
                return StarletteJSONResponse(card_data)

            break

    if _agent_json_route is not None:
        app.add_api_route("/.well-known/agent.json", _agent_json_route, methods=["GET"])
        logger.info("Added /.well-known/agent.json route (LiteLLM-compatible agent card)")
    else:
        logger.warning("Could not find agent-card.json route to proxy for agent.json")

    # Patch the POST / route app to unwrap result.task → result
    _patch_handle_requests(app)

    return app


def main() -> None:
    """
    Official server entrypoint for a2a_adapter.

    Creates a Settings from environment variables and runs the A2A server
    on the configured host/port.

    This is the preferred way to start the patched A2A server in production.
    Use this instead of the deprecated start_patched.py entrypoint.
    """
    settings_cls: type[BaseSettings] = Settings
    settings = cast(Settings, settings_cls())
    app = create_app(settings)
    uvicorn.run(
        app,
        host=settings.a2a_host,
        port=settings.a2a_port,
        log_level=settings.a2a_log_level.lower(),
    )


if __name__ == "__main__":
    main()
