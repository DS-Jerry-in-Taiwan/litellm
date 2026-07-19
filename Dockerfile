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

# Install curl for ECS container health checks.
RUN apk add --no-cache curl

# ── Phase E: Codebase Memory MCP ─────────────────────────────────────────────
# Install DeusData/codebase-memory-mcp with pinned version and checksum verification.
# No external API key required; runs as local stdio MCP server.
ARG CBM_VERSION=v0.9.0
ARG CBM_BASE_URL=https://github.com/DeusData/codebase-memory-mcp/releases/download

# Download checksums file and asset in a single layer to keep image size minimal.
# Note: tar and sha256sum are provided by BusyBox in the Alpine/Chainguard base image,
# not separate installable packages in this image's apk repository.
RUN \
    # Download checksums.txt for integrity verification
    curl -fsSL "${CBM_BASE_URL}/${CBM_VERSION}/checksums.txt" \
         -o /tmp/checksums.txt && \
    # Extract expected SHA256 for the amd64 portable tarball
    CBM_CHECKSUM=$(grep "codebase-memory-mcp-linux-amd64-portable.tar.gz" /tmp/checksums.txt \
                   | awk '{print $1}') && \
    [ -n "${CBM_CHECKSUM}" ] || { echo "ERROR: checksum not found in checksums.txt"; exit 1; } && \
    # Download and verify the pinned asset
    curl -fsSL "${CBM_BASE_URL}/${CBM_VERSION}/codebase-memory-mcp-linux-amd64-portable.tar.gz" \
         -o /tmp/cbm.tar.gz && \
    echo "${CBM_CHECKSUM}  /tmp/cbm.tar.gz" | sha256sum -c && \
    mkdir -p /usr/local/bin && \
    # Extract binary to /usr/local/bin
    tar -xzf /tmp/cbm.tar.gz -C /usr/local/bin/ codebase-memory-mcp && \
    chmod +x /usr/local/bin/codebase-memory-mcp && \
    # Cleanup build artifacts
    rm -f /tmp/checksums.txt /tmp/cbm.tar.gz

# Copy runtime artifacts into /app/
COPY litellm-entrypoint.sh /app/litellm-entrypoint.sh
COPY patch_metrics.py /app/patch_metrics.py

# Entrypoint runs the wrapper which patches + starts LiteLLM
ENTRYPOINT ["/bin/sh", "/app/litellm-entrypoint.sh"]
CMD ["--port", "4000"]
