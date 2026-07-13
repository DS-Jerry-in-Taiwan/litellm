"""
Test script for PatchedOpencodeUpstreamClient (subclass-based, no apply_patch).

Verifies:
1. PatchedOpencodeUpstreamClient.send_message() returns valid OpencodeMessage
   without raising UpstreamContractError (v1.17.13 empty body handling)
2. app.state.upstream_client is PatchedOpencodeUpstreamClient when using
   server.create_app() (class injection)

Exit code 0 = all tests passed.
Exit code 1 = test failed.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

# Ensure a2a_adapter is importable
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from opencode_a2a.config import Settings, StaticAuthCredentialSettings
from opencode_a2a.opencode_upstream_client import (
    OpencodeUpstreamClient,
    OpencodeMessage,
    UpstreamContractError,
)

from a2a_adapter.client import PatchedOpencodeUpstreamClient
from a2a_adapter.server import create_app

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)

OPENCODE_BASE_URL = "http://127.0.0.1:4096"


def make_settings() -> Settings:
    """Build a minimal Settings object pointing at local opencode serve :4096."""
    # Clear any env vars that could interfere with Settings
    for k in list(os.environ.keys()):
        if k.startswith("OPENCODE_") or k.startswith("A2A_"):
            del os.environ[k]
    return Settings(
        opencode_base_url=OPENCODE_BASE_URL,
        a2a_static_auth_credentials=[
            StaticAuthCredentialSettings(
                scheme="bearer",
                principal="test-agent",
                token="test-token",
            )
        ],
    )


# ---------------------------------------------------------------------------
# Test 1: PatchedOpencodeUpstreamClient.send_message() succeeds (no exception)
# ---------------------------------------------------------------------------

async def test_patched_send_message_succeeds() -> bool:
    """Verify PatchedOpencodeUpstreamClient.send_message() handles empty body gracefully."""
    settings = make_settings()
    client = PatchedOpencodeUpstreamClient(settings)

    session_id = await client.create_session()
    logger.info("Created session: %s", session_id)

    try:
        result = await client.send_message(session_id, text="hello from subclass test")
        logger.info(
            "Result: text=%r, session_id=%r, message_id=%r",
            result.text,
            result.session_id,
            result.message_id,
        )
        # Verify returned object is a valid OpencodeMessage
        if not isinstance(result, OpencodeMessage):
            logger.error("FAIL: result is not OpencodeMessage: %s", type(result))
            return False
        if result.session_id != session_id:
            logger.error("FAIL: session_id mismatch: expected=%s, got=%s", session_id, result.session_id)
            return False
        logger.info("PASS: PatchedOpencodeUpstreamClient.send_message returned valid OpencodeMessage")
        return True
    except UpstreamContractError as e:
        logger.error("FAIL: PatchedOpencodeUpstreamClient raised UpstreamContractError: %s", e)
        return False
    except Exception as e:
        logger.error("FAIL: Unexpected error: %s (%s)", type(e).__name__, e)
        return False
    finally:
        await client.close()


# ---------------------------------------------------------------------------
# Test 2: Original OpencodeUpstreamClient.send_message() raises UpstreamContractError
# ---------------------------------------------------------------------------

async def test_original_send_message_raises() -> bool:
    """Verify that the original (unpatched) OpencodeUpstreamClient raises UpstreamContractError."""
    settings = make_settings()
    client = OpencodeUpstreamClient(settings)

    session_id = await client.create_session()
    logger.info("Created session: %s", session_id)

    try:
        await client.send_message(session_id, text="this should fail with v1.17.13")
        logger.error("FAIL: Original send_message did NOT raise UpstreamContractError")
        return False
    except UpstreamContractError:
        logger.info("PASS: Original send_message raised UpstreamContractError as expected (v1.17.13 empty body)")
        return True
    except Exception as e:
        logger.error("FAIL: Original raised unexpected error: %s (%s)", type(e).__name__, e)
        return False
    finally:
        await client.close()


# ---------------------------------------------------------------------------
# Test 3: server.create_app() injects PatchedOpencodeUpstreamClient
# ---------------------------------------------------------------------------

async def test_create_app_injects_subclass() -> bool:
    """Verify that server.create_app() makes app.state.upstream_client a subclass."""
    settings = make_settings()
    app = create_app(settings)

    upstream_client = app.state.upstream_client
    client_class_name = type(upstream_client).__name__
    logger.info("app.state.upstream_client type: %s", client_class_name)

    if client_class_name != "PatchedOpencodeUpstreamClient":
        logger.error(
            "FAIL: app.state.upstream_client is %s, expected PatchedOpencodeUpstreamClient",
            client_class_name,
        )
        return False

    logger.info("PASS: server.create_app() correctly injects PatchedOpencodeUpstreamClient")
    return True


# ---------------------------------------------------------------------------
# Test 4: PatchedOpencodeUpstreamClient has correct send_message signature
# ---------------------------------------------------------------------------

async def test_signature_preserved() -> bool:
    """Verify the subclass send_message has the same signature as the parent."""
    import inspect

    parent_sig = inspect.signature(OpencodeUpstreamClient.send_message)
    child_sig = inspect.signature(PatchedOpencodeUpstreamClient.send_message)

    parent_params = list(parent_sig.parameters.keys())
    child_params = list(child_sig.parameters.keys())

    # Both should have 'self', 'session_id', 'text', 'parts', 'directory',
    # 'workspace_id', 'model_override', 'timeout_override'
    if parent_params != child_params:
        logger.error(
            "FAIL: Signature mismatch — parent=%s, child=%s",
            parent_params,
            child_params,
        )
        return False

    logger.info("PASS: send_message signature preserved: %s", parent_params)
    return True


# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

async def run_tests() -> bool:
    """Run all tests and report results."""
    all_passed = True

    # Test 1
    logger.info("=" * 60)
    logger.info("TEST 1: PatchedOpencodeUpstreamClient.send_message succeeds")
    logger.info("=" * 60)
    if not await test_patched_send_message_succeeds():
        all_passed = False
        logger.error("TEST 1 FAILED")
    else:
        logger.info("TEST 1 PASSED")

    # Test 2
    logger.info("=" * 60)
    logger.info("TEST 2: Original send_message raises UpstreamContractError")
    logger.info("=" * 60)
    if not await test_original_send_message_raises():
        all_passed = False
        logger.error("TEST 2 FAILED")
    else:
        logger.info("TEST 2 PASSED")

    # Test 3
    logger.info("=" * 60)
    logger.info("TEST 3: server.create_app() injects subclass")
    logger.info("=" * 60)
    if not await test_create_app_injects_subclass():
        all_passed = False
        logger.error("TEST 3 FAILED")
    else:
        logger.info("TEST 3 PASSED")

    # Test 4
    logger.info("=" * 60)
    logger.info("TEST 4: send_message signature preserved")
    logger.info("=" * 60)
    if not await test_signature_preserved():
        all_passed = False
        logger.error("TEST 4 FAILED")
    else:
        logger.info("TEST 4 PASSED")

    return all_passed


async def main() -> int:
    logger.info("Starting PatchedOpencodeUpstreamClient tests (Phase 4 — class-based)")
    logger.info("Target: %s", OPENCODE_BASE_URL)

    success = await run_tests()

    logger.info("")
    if success:
        logger.info("=" * 60)
        logger.info("ALL TESTS PASSED")
        logger.info("=" * 60)
        return 0
    else:
        logger.error("=" * 60)
        logger.error("SOME TESTS FAILED")
        logger.error("=" * 60)
        return 1


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    sys.exit(exit_code)
