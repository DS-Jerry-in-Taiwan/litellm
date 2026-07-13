"""
Patch LiteLLM's proxy_server.py to add an explicit /metrics GET route.
Workaround for LiteLLM 1.89.x regression where app.mount('/metrics', make_asgi_app())
doesn't properly register the metrics endpoint.

Strategy: Append module-level code at the END of proxy_server.py that:
1. Registers @app.get('/metrics') and @app.get('/metrics/') routes
2. Uses prometheus_client.generate_latest() to serve metrics
3. Runs at import time (before any middleware or server start)

This bypasses the broken app.mount() mechanism entirely.
"""
import glob
import os
import sys

# ── Path constants ────────────────────────────────────────────────────────────

LEGACY_PROXY_SERVER = "/app/litellm/proxy/proxy_server.py"
"""Legacy path used by local development / older LiteLLM installs."""

VENV_PROXY_SERVER_GLOB = "/app/.venv/lib/python*/site-packages/litellm/proxy/proxy_server.py"
"""Glob pattern for venv-installed LiteLLM (e.g. python3.12, python3.13)."""


# ── Path resolution ───────────────────────────────────────────────────────────

def _build_candidates():
    """
    Build the ordered list of proxy_server.py candidates.

    Search order:
      1. /app/litellm/proxy/proxy_server.py                  (legacy)
      2. /app/.venv/lib/python*/site-packages/litellm/...    (venv, sorted)

    glob.glob() is called on every invocation so that test mocks on
    os.path.exists are effective (candidates are not pre-computed at import
    time, avoiding real-filesystem dependency in unit tests).
    """
    venv_candidates = sorted(glob.glob(VENV_PROXY_SERVER_GLOB))
    return [LEGACY_PROXY_SERVER] + venv_candidates


def get_proxy_server_candidates():
    """Return the list of paths that will be searched, in search order."""
    return _build_candidates()


def resolve_proxy_server_path():
    """
    Resolve the actual proxy_server.py path.

    Searches in order:
      1. /app/litellm/proxy/proxy_server.py          (legacy)
      2. /app/.venv/lib/python*/site-packages/litellm/proxy/proxy_server.py  (venv)

    Returns the first path that exists.

    Raises:
        FileNotFoundError: if no candidate path exists; error message lists
                           every searched path.
    """
    candidates = _build_candidates()
    searched = []
    for candidate in candidates:
        searched.append(candidate)
        if os.path.exists(candidate):
            return candidate

    # All candidates searched, none found → fail fast with the full list
    searched_str = "\n  - ".join(searched)
    raise FileNotFoundError(
        f"[patch_metrics] proxy_server.py not found. Searched:\n  - {searched_str}"
    )


# ── Module-level patch code ───────────────────────────────────────────────────

MODULE_LEVEL_CODE = r'''

# --- patch_metrics_route (module-level) ---
# Workaround: LiteLLM 1.89.x app.mount('/metrics', ...) is broken.
# Register explicit GET routes instead.
import sys as _pm_sys
from prometheus_client import generate_latest as _pm_generate, CONTENT_TYPE_LATEST as _pm_ctype
from starlette.responses import Response as _pm_Response

try:
    @app.get("/metrics")
    @app.get("/metrics/")
    async def _pm_metrics_route():
        return _pm_Response(
            content=_pm_generate(),
            media_type=_pm_ctype,
        )
except Exception as _pm_e:
    _pm_sys.stderr.write(f"[metrics_patch] ERROR: {_pm_e}\n")
'''


def main():
    proxy_server = resolve_proxy_server_path()
    print(f"[patch_metrics] Using proxy_server.py: {proxy_server}")

    with open(proxy_server) as f:
        content = f.read()

    # Remove any existing patch_metrics_route block (re-applies cleanly)
    marker = "# --- patch_metrics_route (module-level) ---"
    if marker in content:
        idx = content.index(marker)
        content = content[:idx].rstrip() + "\n"
        print("[patch_metrics] Removed old patch")

    # Append module-level code at the end of the file
    content = content.rstrip() + "\n" + MODULE_LEVEL_CODE + "\n"

    with open(proxy_server, "w") as f:
        f.write(content)

    print("[patch_metrics] Patch applied successfully")


if __name__ == "__main__":
    main()
