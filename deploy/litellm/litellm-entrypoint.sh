#!/bin/sh
# LiteLLM entrypoint wrapper — patches /metrics route before starting
# MUST run in a single Python process to avoid stale module caching.
set -e

exec python3 -c "
import sys, os

# ── Step 1: Patch proxy_server.py ──────────────────────────────
# Use patch_metrics.py module to do the patching
sys.path.insert(0, '/app')
import patch_metrics
patch_metrics.main()
sys.stderr.write('[entrypoint] Patch applied\n')

# ── Step 2: Clear all cached litellm modules ────────────────────
for key in list(sys.modules):
    if key.startswith('litellm'):
        del sys.modules[key]

# ── Step 3: Import litellm and start the proxy ─────────────────
import litellm
from litellm import run_server

sys.stderr.write('[entrypoint] litellm imported, starting server...\n')

# Forward CLI arguments to run_server (Click uses sys.argv)
sys.argv = ['litellm_proxy'] + sys.argv[1:]
run_server()
" "${@}"
