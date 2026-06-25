# =============================================================================
# LiteLLM Custom Runtime Image — Phase 1 Image Parity
# =============================================================================
# Base: Official LiteLLM stable image
# Purpose: Bake litellm-entrypoint.sh + patch_metrics.py into the image so
#          Local Compose and future AWS ECS Fargate use the same runtime.
#
# Design decisions:
#   - ENTRYPOINT uses exec form with explicit /bin/sh for shell expansion
#   - patch_metrics.py runs at container start (at import time, before run_server)
#   - config.yaml is NOT copied; local bind mount allows config edits without rebuild
#   - .env is NOT copied; secrets must come from env_file in compose or AWS Secrets
# =============================================================================

FROM docker.litellm.ai/berriai/litellm:main-stable

# Copy runtime artifacts into /app/
COPY litellm-entrypoint.sh /app/litellm-entrypoint.sh
COPY patch_metrics.py /app/patch_metrics.py

# Entrypoint runs the wrapper which patches + starts LiteLLM
ENTRYPOINT ["/bin/sh", "/app/litellm-entrypoint.sh"]
CMD ["--port", "4000"]
