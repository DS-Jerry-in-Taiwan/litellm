"""
Monkey-patch for OpencodeUpstreamClient.send_message().

DEPRECATED (Phase 4): This module is kept for backward compatibility only.
Do not use in new code. Migrate to:

    # Class-based approach (preferred)
    from a2a_adapter.client import PatchedOpencodeUpstreamClient
    client = PatchedOpencodeUpstreamClient(settings)

    # Or via the server entrypoint
    from a2a_adapter.server import main  # replaces apply_patch + opencode-a2a serve

This module patches OpencodeUpstreamClient.send_message() at the class level
to handle HTTP 200 empty body responses from OpenCode v1.17.13 POST /session/{id}/message.
OpenCode v1.17.13 returns HTTP 200 with empty body after storing the message,
but opencode-a2a v1.1.1 expects a JSON body and raises UpstreamContractError.

The apply_patch() / remove_patch() functions are deprecated and should not
be used in production. The class-based PatchedOpencodeUpstreamClient in
a2a_adapter/client.py provides the same behavior via inheritance.
"""

from __future__ import annotations

import logging
import warnings
from typing import Any

from opencode_a2a.opencode_upstream_client import (
    OpencodeUpstreamClient,
    OpencodeMessage,
    UpstreamContractError,
    _UNSET,
)

logger = logging.getLogger(__name__)

# Keep a reference to the original method
_original_send_message = OpencodeUpstreamClient.send_message


async def patched_send_message(
    self,
    session_id: str,
    text: str | None = None,
    *,
    parts: list[dict[str, Any]] | tuple[dict[str, Any], ...] | None = None,
    directory: str | None = None,
    workspace_id: str | None = None,
    model_override: dict[str, Any] | None = None,
    timeout_override: Any = _UNSET,
) -> OpencodeMessage:
    """
    Patched send_message that handles OpenCode v1.17.13 empty body response.

    OpenCode returns HTTP 200 with empty body from POST /session/{id}/message.
    The original _post_json() -> _decode_json_response() raises UpstreamContractError.
    This patch catches that error and returns a minimal OpencodeMessage.
    """
    try:
        return await _original_send_message(
            self,
            session_id,
            text,
            parts=parts,
            directory=directory,
            workspace_id=workspace_id,
            model_override=model_override,
            timeout_override=timeout_override,
        )
    except UpstreamContractError:
        logger.info(
            "send_message caught UpstreamContractError for session=%s "
            "(expected: OpenCode v1.17.13 empty body). Returning minimal OpencodeMessage.",
            session_id,
        )
        # Extract text from parts if text is None
        text_content: str = text if text else ""
        if not text_content and parts:
            for part in parts:
                if isinstance(part, dict) and "text" in part:
                    text_content = str(part["text"])
                    break
        # For empty body: no message_id available from upstream
        return OpencodeMessage(
            text=text_content,
            session_id=session_id,
            message_id=None,  # empty body: no message_id from upstream
            raw={},  # no raw data from empty body
        )


def apply_patch() -> None:
    """
    Replace OpencodeUpstreamClient.send_message with the patched version.

    DEPRECATED: Use a2a_adapter.client.PatchedOpencodeUpstreamClient instead.
    This function exists only for backward compatibility with existing callers.
    """
    warnings.warn(
        "apply_patch() is deprecated. Use a2a_adapter.client.PatchedOpencodeUpstreamClient "
        "or a2a_adapter.server.create_app() instead.",
        DeprecationWarning,
        stacklevel=2,
    )
    OpencodeUpstreamClient.send_message = patched_send_message  # type: ignore[method-assign]
    logger.info("Applied monkey-patch to OpencodeUpstreamClient.send_message (deprecated)")


def remove_patch() -> None:
    """
    Restore the original send_message method.

    DEPRECATED: This function exists only for backward compatibility.
    """
    warnings.warn(
        "remove_patch() is deprecated.",
        DeprecationWarning,
        stacklevel=2,
    )
    OpencodeUpstreamClient.send_message = _original_send_message  # type: ignore[method-assign]
    logger.info("Removed monkey-patch from OpencodeUpstreamClient.send_message (deprecated)")
