"""
client.py — PatchedOpencodeUpstreamClient for OpenCode v1.17.13 empty-body compatibility.

This module provides PatchedOpencodeUpstreamClient(OpencodeUpstreamClient) which
overrides send_message() to gracefully handle HTTP 200 empty body responses
from OpenCode v1.17.13 POST /session/{id}/message.

Usage (preferred over patches.py):
    from a2a_adapter.client import PatchedOpencodeUpstreamClient
    client = PatchedOpencodeUpstreamClient(settings)

Or via the server entrypoint (recommended for production):
    from a2a_adapter.server import create_app, main
"""

from __future__ import annotations

import logging
from collections.abc import Mapping, Sequence
from typing import Any

from opencode_a2a.opencode_upstream_client import (
    OpencodeMessage,
    OpencodeUpstreamClient,
    UpstreamContractError,
    _UNSET,
)

logger = logging.getLogger(__name__)


class PatchedOpencodeUpstreamClient(OpencodeUpstreamClient):
    """
    OpenCode upstream client with v1.17.13 empty-body send_message compatibility.

    OpenCode v1.17.13 returns HTTP 200 with an empty body from POST /session/{id}/message
    after storing the message, but opencode-a2a v1.1.1 expects a JSON body and raises
    UpstreamContractError. This subclass catches that error and returns a minimal
    OpencodeMessage so the A2A handler chain proceeds normally.

    All other methods are inherited from OpencodeUpstreamClient unchanged.
    """

    async def send_message(
        self,
        session_id: str,
        text: str | None = None,
        *,
        parts: Sequence[Mapping[str, Any]] | None = None,
        directory: str | None = None,
        workspace_id: str | None = None,
        model_override: Mapping[str, Any] | None = None,
        timeout_override: float | None | object = _UNSET,
    ) -> OpencodeMessage:
        """
        Override send_message to handle OpenCode v1.17.13 empty body response.

        Calls super().send_message() and catches UpstreamContractError. On that
        error, extracts whatever text is available (from the top-level `text`
        parameter or from the first text part in `parts`) and returns a minimal
        OpencodeMessage(session_id=session_id, text=..., message_id=None, raw={}).

        This mirrors the behavior of the deprecated patches.py monkey-patch but
        uses class inheritance instead of method replacement.
        """
        try:
            return await super().send_message(
                session_id,
                text,
                parts=parts,
                directory=directory,
                workspace_id=workspace_id,
                model_override=model_override,
                timeout_override=timeout_override,
            )
        except UpstreamContractError:
            # Extract text from the call's text parameter or from parts
            text_content: str = text if text else ""
            if not text_content and parts:
                for part in parts:
                    if isinstance(part, Mapping) and "text" in part:
                        text_content = str(part["text"])
                        break
            logger.info(
                "PatchedOpencodeUpstreamClient.send_message handled OpenCode v1.17.13 "
                "empty body for session=%s; returning minimal OpencodeMessage.",
                session_id,
            )
            return OpencodeMessage(
                text=text_content,
                session_id=session_id,
                message_id=None,
                raw={},
            )
