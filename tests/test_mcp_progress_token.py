"""
Regression tests for MCP integer progressToken fix (PR #32402).
These tests verify _capture_host_progress_callback behavior without
requiring a running LiteLLM instance.
"""
import unittest
from unittest.mock import MagicMock, AsyncMock
from typing import Optional, Callable


def _capture_host_progress_callback(host_server) -> Optional[Callable]:
    """
    Port of the fixed _capture_host_progress_callback from
    litellm/proxy/_experimental/mcp_server/server.py (v1.94.0).

    The fix (PR #32402) changed:
    1. `if not (host_token and ...)` -> `if host_token is None or not (...)`
    2. `host_token[:8]` -> `str(host_token)[:8]`
    """
    try:
        host_ctx = host_server.request_context
    except Exception:
        return None

    if not (host_ctx and hasattr(host_ctx, "meta") and host_ctx.meta):
        return None

    host_token = getattr(host_ctx.meta, "progressToken", None)

    # FIX: Use explicit None check instead of truthiness
    # so integer 0 is not treated as absent
    if host_token is None or not (hasattr(host_ctx, "session") and host_ctx.session):
        return None

    host_session = host_ctx.session

    async def forward_progress(progress: float, total: Optional[float] = None):
        await host_session.send_progress_notification(
            progress_token=host_token,
            progress=progress,
            total=total,
        )

    return forward_progress


class TestCaptureHostProgressCallback(unittest.TestCase):
    """Regression tests for integer progressToken fix."""

    def _make_host_server(self, progress_token):
        """Helper: create mocked host_server with given progressToken."""
        host_server = MagicMock()
        host_ctx = MagicMock()
        host_ctx.meta.progressToken = progress_token
        host_ctx.session = AsyncMock()
        host_server.request_context = host_ctx
        return host_server

    def test_integer_progress_token_returns_callable(self):
        """Integer progressToken (=42) must return a callable (not TypeError)."""
        host_server = self._make_host_server(42)
        result = _capture_host_progress_callback(host_server)
        self.assertIsNotNone(result)
        self.assertTrue(callable(result))

    def test_zero_progress_token_returns_callable(self):
        """progressToken=0 (valid per MCP spec) must return a callable."""
        host_server = self._make_host_server(0)
        result = _capture_host_progress_callback(host_server)
        self.assertIsNotNone(result)
        self.assertTrue(callable(result))

    def test_string_progress_token_returns_callable(self):
        """String progressToken must remain supported."""
        host_server = self._make_host_server("tok-1")
        result = _capture_host_progress_callback(host_server)
        self.assertIsNotNone(result)
        self.assertTrue(callable(result))

    def test_none_progress_token_returns_none(self):
        """No progressToken must return None (no forwarding)."""
        host_server = self._make_host_server(None)
        result = _capture_host_progress_callback(host_server)
        self.assertIsNone(result)

    def test_integer_token_value_preserved(self):
        """The original integer value must be passed to send_progress_notification."""
        host_server = self._make_host_server(42)
        callback = _capture_host_progress_callback(host_server)
        import asyncio
        asyncio.run(callback(0.5, 1.0))
        host_server.request_context.session.send_progress_notification.assert_awaited_once_with(
            progress_token=42, progress=0.5, total=1.0
        )


if __name__ == "__main__":
    unittest.main()
