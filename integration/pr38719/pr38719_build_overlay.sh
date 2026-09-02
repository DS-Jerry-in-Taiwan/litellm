#!/bin/sh
# =============================================================================
# PR #38719 — build-time overlay of ChatGPT Responses SSE-recovery fix
# =============================================================================
# Installs the committed integrated `transformation.py`
# (v1.94.0 baseline + exact PR #38719 delta, sha-pinned) over the v1.94.0 base
# image's *installed* litellm package at IMAGE BUILD time (Dockerfile layer).
#
# This is NOT a runtime monkeypatch: it runs once when the image is built and
# the merged file is baked into the layer.
#
# Deterministic + fail-closed: baseline and merged sha256 are pinned here, so
# an unknown base or a tampered overlay both abort the build. The final file is
# py_compiled and its method marker checked.
# =============================================================================
set -eu

# ---- exact committed values (kept here and in SOURCE_PROVENANCE.md) --------
EXPECT_BASELINE_SHA256="e6cd3fa0244f706254a8e90f932b494e07cf73c8502ffc00942304c3ae0c034e"
EXPECT_MERGED_SHA256="75f9f0b5578c4e3c518bcad886b7a706bd0087b54b57a1324887018684750f7e"
OVERLAY_SRC="/tmp/transformation_38719.py"
OVERLAY_SHA256="75f9f0b5578c4e3c518bcad886b7a706bd0087b54b57a1324887018684750f7e"
METHOD_MARKER="def transform_streaming_response("
TARGET_GLOB="/app/.venv/lib/python*/site-packages/litellm/llms/chatgpt/responses/transformation.py"

echo "[pr38719] overlay start"

# 0) verify the committed overlay file is intact ----------------------------
[ -f "${OVERLAY_SRC}" ] || { echo "ERROR: overlay file not found: ${OVERLAY_SRC}"; exit 1; }
echo "${OVERLAY_SHA256}  ${OVERLAY_SRC}" | sha256sum -c - || { echo "ERROR: overlay sha256 mismatch"; exit 1; }

# 1) resolve the SINGLE installed target (fail on 0 or >1 matches) -----------
count=0
for base in ${TARGET_GLOB}; do
    [ -f "$base" ] || continue
    count=$((count + 1))
    INSTALLED="$base"
done
[ "$count" -eq 1 ] || { echo "ERROR: expected 1 installed transformation.py, found $count"; exit 1; }
echo "[pr38719] target: ${INSTALLED}"

# 2) baseline the pre-overlay installed file (fail-closed on baseline change) -
BS=$(sha256sum "$INSTALLED" | awk '{print $1}')
echo "[pr38719] pre-overlay sha256: ${BS}"
[ "${BS}" = "${EXPECT_BASELINE_SHA256}" ] || { echo "ERROR: baseline mismatch (installed: ${BS}, expected: ${EXPECT_BASELINE_SHA256}). Refuse to overlay unknown baseline."; exit 1; }

# 3) deterministic copy of the committed integrated file ----------------------
cp "${OVERLAY_SRC}" "$INSTALLED"

# 4) verify the post-overlay result sha256 ------------------------------------
MS=$(sha256sum "$INSTALLED" | awk '{print $1}')
echo "[pr38719] post-overlay sha256: ${MS}"
[ "${MS}" = "${EXPECT_MERGED_SHA256}" ] || { echo "ERROR: merged result sha256 mismatch (got ${MS}, expected ${EXPECT_MERGED_SHA256})"; exit 1; }

# 5) sanity compile + marker presence -----------------------------------------
python3 -m py_compile "$INSTALLED" || { echo "ERROR: overlaid file failed py_compile"; exit 1; }
grep -q "${METHOD_MARKER}" "$INSTALLED" || { echo "ERROR: PR method marker missing after overlay"; exit 1; }

echo "[pr38719] overlay OK: baseline verified, exact integrated file installed, merged sha256 verified, compiled"
