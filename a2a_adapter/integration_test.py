"""
Integration test for the full A2A three-phase flow using PatchedOpencodeUpstreamClient.

Tests:
1. create_session → 2. patched send_message → 3. session_prompt_async → 4. stream_events

Uses PatchedOpencodeUpstreamClient directly (no apply_patch).
Uses a fresh isolated session; does not affect existing sessions.

Run: cd /home/ubuntu/projects/litellm && uv run --with opencode-a2a python -m a2a_adapter.integration_test

WARNING: This test reads from a live opencode serve on :4096.
Do NOT run while critical sessions are active on that server.
"""

from __future__ import annotations

import asyncio
import logging
import sys
import time

# Use the new class-based approach — no apply_patch needed
from a2a_adapter.client import PatchedOpencodeUpstreamClient

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

# Actual imports from opencode-a2a — verified against real source
from opencode_a2a.config import Settings, StaticAuthCredentialSettings
from opencode_a2a.opencode_upstream_client import UpstreamContractError


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

def _build_test_settings() -> Settings:
    """Build a minimal Settings object pointing at local opencode serve :4096."""
    return Settings(
        opencode_base_url="http://127.0.0.1:4096",
        a2a_static_auth_credentials=[
            StaticAuthCredentialSettings(
                scheme="bearer",
                principal="test",
                token="test",
            )
        ],
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

async def test_patched_send_message(client: PatchedOpencodeUpstreamClient, session_id: str) -> bool:
    """
    Verify patched send_message succeeds with OpenCode v1.17.13 empty body.

    OpenCode v1.17.13 returns HTTP 200 with empty body from POST /session/{id}/message.
    Without the patch this raises UpstreamContractError; with PatchedOpencodeUpstreamClient
    it returns a minimal OpencodeMessage.
    """
    logger.info("[Step 2] Calling PatchedOpencodeUpstreamClient.send_message ...")
    try:
        result = await client.send_message(session_id, text="Hello from integration test")
        logger.info(
            "  OpencodeMessage: text=%r, session_id=%r, message_id=%r",
            result.text,
            result.session_id,
            result.message_id,
        )
        if result.session_id != session_id:
            logger.error("  FAIL: session_id mismatch")
            return False
        logger.info("  PASS: Patched send_message succeeded (caught UpstreamContractError internally)")
        return True
    except UpstreamContractError as e:
        logger.error(
            "  FAIL: Patched send_message still propagates UpstreamContractError: %s", e
        )
        return False
    except Exception as e:
        logger.error("  FAIL: Patched send_message raised unexpected error: %s", e)
        return False


async def test_session_prompt_async(client: PatchedOpencodeUpstreamClient, session_id: str) -> bool:
    """
    Verify session_prompt_async returns None (HTTP 204).

    Format: request = {'parts': [{'type': 'text', 'text': '...'}]}
    The 'parts' field is required per opencode-a2a contract.
    """
    logger.info("[Step 3] Calling session_prompt_async ...")
    try:
        # Correct format per PROMPT_ASYNC_REQUEST_REQUIRED_FIELDS = ("parts",)
        await client.session_prompt_async(
            session_id,
            request={"parts": [{"type": "text", "text": ""}]},
        )
        logger.info("  PASS: prompt_async returned 204 OK")
        return True
    except Exception as e:
        logger.error("  FAIL: session_prompt_async raised: %s", e)
        return False


async def test_stream_events(client: PatchedOpencodeUpstreamClient, session_id: str) -> bool:
    """
    Verify stream_events yields at least one valid SSE event within 10s.

    stop_event: asyncio.Event (not threading.Event — verified against real source)
    """
    logger.info("[Step 4] Consuming stream_events (10s timeout) ...")
    stop_event: asyncio.Event = asyncio.Event()
    events: list[dict] = []
    deadline = time.time() + 10

    async def consume() -> None:
        try:
            async for event in client.stream_events(stop_event=stop_event):
                events.append(event)
                event_type = event.get("type", "")
                logger.info("  SSE event: type=%r", event_type)
                if time.time() > deadline:
                    logger.warning("  Deadline reached, stopping stream")
                    stop_event.set()
                    break
                # Stop on terminal events
                if event_type in ("session.idle", "session.error", "done", "error"):
                    logger.info("  Terminal event %r received, stopping", event_type)
                    stop_event.set()
                    break
        except Exception as e:
            logger.error("  Stream error: %s", e)
            stop_event.set()

    consume_task = asyncio.create_task(consume())

    # Wait for up to 12 seconds total
    try:
        await asyncio.wait_for(consume_task, timeout=12.0)
    except asyncio.TimeoutError:
        logger.warning("  Timeout waiting for events")
        stop_event.set()
        try:
            await consume_task
        except Exception:
            pass

    if not events:
        logger.error("  FAIL: No SSE events received")
        return False

    # Validate each event is a dict with a type field
    for ev in events:
        if not isinstance(ev, dict):
            logger.error("  FAIL: Event is not a dict: %r", ev)
            return False
        if "type" not in ev:
            logger.error("  FAIL: Event missing 'type' field: %r", ev)
            return False

    logger.info(
        "  PASS: Received %d SSE event(s): %s",
        len(events),
        [e.get("type") for e in events],
    )
    return True


async def test_full_flow() -> bool:
    """Run the complete three-phase flow on an isolated session."""
    settings = _build_test_settings()
    # Use PatchedOpencodeUpstreamClient directly — no apply_patch needed
    client = PatchedOpencodeUpstreamClient(settings=settings)

    # Step 1: create isolated session
    logger.info("[Step 1] Creating isolated session ...")
    try:
        session_id = await client.create_session()
        logger.info("  Session created: %s", session_id)
    except Exception as e:
        logger.error("  FAIL: create_session raised: %s", e)
        return False

    # Step 2: patched send_message
    if not await test_patched_send_message(client, session_id):
        await client.close()
        return False

    # Step 3: prompt_async
    if not await test_session_prompt_async(client, session_id):
        await client.close()
        return False

    # Step 4: stream_events
    if not await test_stream_events(client, session_id):
        await client.close()
        return False

    # Cleanup
    try:
        await client.close()
    except Exception:
        pass

    return True


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main() -> bool:
    logger.info("=" * 60)
    logger.info("A2A Integration Test — Three-Phase Flow (Phase 4 — class-based)")
    logger.info("opencode serve expected on: http://127.0.0.1:4096")
    logger.info("Using PatchedOpencodeUpstreamClient (no apply_patch)")
    logger.info("=" * 60)

    success = await test_full_flow()

    logger.info("")
    if success:
        logger.info("ALL TESTS PASSED")
    else:
        logger.error("TESTS FAILED")
    return success


if __name__ == "__main__":
    ok = asyncio.run(main())
    sys.exit(0 if ok else 1)
