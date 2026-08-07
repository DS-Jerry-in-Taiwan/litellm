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

# Pin to v1.94.0 by immutable digest for MCP integer progressToken fix (PR #32402).
# Rationale: v1.94.0 contains PR #32402 which fixes TypeError on integer progressToken.
# Replaces main-stable floating tag with immutable digest for reproducibility.
# v1.94.0 digest (linux/amd64): sha256:65d84a2282137b4dc73bbe184650a7c807177c533e4223b3bfbc87963fe3fabe
# Rollback digest (v1.92.0): sha256:9ef6f45bc0104940571765e610c52a1d761b5ec85efcd193795281086ee61277
# Dual registry: docker.litellm.ai/berriai/litellm == ghcr.io/berriai/litellm (same digest)
FROM docker.litellm.ai/berriai/litellm:v1.94.0@sha256:65d84a2282137b4dc73bbe184650a7c807177c533e4223b3bfbc87963fe3fabe

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

# ── Phase F1: Sequential Thinking MCP ─────────────────────────────────────────
# Install @modelcontextprotocol/server-sequential-thinking as a pre-bundled
# self-contained executable. No npm/node_modules required at runtime.
#
# Build strategy (done locally, outside Docker — see prebuilt/BUILD.md):
#   1. Download npm tarball from registry.npmjs.org
#   2. Extract and npm install --omit=dev (with local npm available)
#   3. Bundle via esbuild (format=cjs, external=node:*) to single CJS file
#   4. Collect required runtime deps (ajv sub-modules) into node_modules/
#   5. Package as tar.gz: mcp-server/{mcp-server-sequential-thinking,node_modules/}
#
# Verification: hex SHA512 of the pre-built tar.gz is verified before extraction.
# Reproducibility: esbuild bundles the app + SDK at build time. Runtime needs only
#   the Node.js interpreter (present in base image) + ajv sub-modules (included).
#
# Version: 2026.7.4 (verified on 2026-07-19)
# Policy: ALLOW_READ — in-memory reasoning, no network/filesystem side effects.
# Source tarball SHA512 (hex): b6647f89e19a7b079f7cb341ac3a751f5c38b27e0ce93379c9649b312f9831f4bed060f23e39cd2b3a82976baa7dd4625f70f8e0f2548708831aab49a7ab4587
# Pre-built package SHA512 (hex): c0953145e5c30ee110aeb213128b335d47c80c18328cff2ecede6a850d40db52dd5a83122f9185cdbcfe5f6adde552be3693d826b5656f317a1b3c2a8010c65b
COPY prebuilt/seqthink-server.tgz /tmp/seqthink-server.tgz

RUN \
    # Verify SHA512 integrity before extraction
    echo "c0953145e5c30ee110aeb213128b335d47c80c18328cff2ecede6a850d40db52dd5a83122f9185cdbcfe5f6adde552be3693d826b5656f317a1b3c2a8010c65b  /tmp/seqthink-server.tgz" | sha512sum -c || { \
        echo "ERROR: SHA512 integrity check failed for sequentialthinking pre-built package"; exit 1; \
    } && \
    # Extract to /usr/local/lib/mcp-servers/
    mkdir -p /usr/local/lib/mcp-servers && \
    tar -xzf /tmp/seqthink-server.tgz -C /usr/local/lib/mcp-servers/ && \
    # Install executable symlink at /usr/local/bin/
    # The bundle.cjs file is the server binary; NODE_PATH points to included deps.
    ln -sf /usr/local/lib/mcp-servers/mcp-server/mcp-server-sequential-thinking /usr/local/bin/mcp-server-sequential-thinking && \
    # Cleanup
    rm -f /tmp/seqthink-server.tgz && \
    echo "INFO: sequentialthinking_mcp installed successfully (no npm required at runtime)"

# Copy runtime artifacts into /app/
COPY litellm-entrypoint.sh /app/litellm-entrypoint.sh
COPY patch_metrics.py /app/patch_metrics.py

# Entrypoint runs the wrapper which patches + starts LiteLLM
ENTRYPOINT ["/bin/sh", "/app/litellm-entrypoint.sh"]
CMD ["--port", "4000"]
