#!/bin/sh
# LiteLLM entrypoint wrapper — patches /metrics route before starting
# Also supports S3 config download and migration mode.
set -e

# ── Optional: Download config from S3 ──────────────────────────
if [ -n "$S3_CONFIG_URL" ]; then
    S3_BUCKET=$(echo "$S3_CONFIG_URL" | sed 's|s3://||' | cut -d/ -f1)
    S3_KEY=$(echo "$S3_CONFIG_URL" | sed 's|s3://||' | cut -d/ -f2-)
    echo "[entrypoint] Downloading config from s3://${S3_BUCKET}/${S3_KEY}"
    python3 -c "
import boto3, sys
s3 = boto3.client('s3')
bucket = '${S3_BUCKET}'
key = '${S3_KEY}'
try:
    s3.download_file(bucket, key, '/app/config.yaml')
    sys.stderr.write('[entrypoint] Config downloaded from S3\n')
except Exception as e:
    sys.stderr.write(f'[entrypoint] WARNING: Could not download config from S3: {e}\n')
    sys.stderr.write('[entrypoint] Falling back to baked config.yaml\n')
"
fi

# ── Migration mode ─────────────────────────────────────────────
if [ "$LITELLM_MODE" = "migrate" ]; then
    echo "[entrypoint] Running in migration mode"
    exec python3 -c "
import sys
sys.path.insert(0, '/app')
import patch_metrics
patch_metrics.main()
import litellm
from litellm.proxy.proxy_cli import run_migrations
sys.argv = ['litellm', '--config', '/app/config.yaml']
run_migrations()
"
fi

# ── Normal server mode ─────────────────────────────────────────
exec python3 -c "
import sys, os

# Step 1: Patch proxy_server.py
sys.path.insert(0, '/app')
import patch_metrics
patch_metrics.main()
sys.stderr.write('[entrypoint] Patch applied\n')

# Step 2: Clear cached litellm modules
for key in list(sys.modules):
    if key.startswith('litellm'):
        del sys.modules[key]

# Step 3: Import litellm and start the proxy
import litellm
from litellm import run_server
sys.stderr.write('[entrypoint] litellm imported, starting server...\n')

sys.argv = ['litellm_proxy'] + sys.argv[1:]
run_server()
" "${@}"
