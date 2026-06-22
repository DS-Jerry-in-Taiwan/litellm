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
import sys

PROXY_SERVER = "/app/litellm/proxy/proxy_server.py"

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
    with open(PROXY_SERVER) as f:
        content = f.read()

    # Remove any existing patch_metrics_route block (re-applies cleanly)
    marker = "# --- patch_metrics_route (module-level) ---"
    if marker in content:
        idx = content.index(marker)
        content = content[:idx].rstrip() + "\n"
        print("[patch_metrics] Removed old patch")

    # Append module-level code at the end of the file
    content = content.rstrip() + "\n" + MODULE_LEVEL_CODE + "\n"

    with open(PROXY_SERVER, "w") as f:
        f.write(content)

    print("[patch_metrics] Patch applied successfully")


if __name__ == "__main__":
    main()
