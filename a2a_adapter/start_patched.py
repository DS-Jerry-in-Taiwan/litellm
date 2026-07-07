"""
start_patched.py — Deprecated compatibility entrypoint for a2a_adapter.

DEPRECATED: This module exists only for backward compatibility.
Use the following instead:

    # Preferred (new) entrypoint
    from a2a_adapter.server import main
    main()  # blocking — runs uvicorn

    # Or programmatically
    from a2a_adapter.server import create_app
    from opencode_a2a.config import Settings
    app = create_app(Settings())

This file re-exports a2a_adapter.server.main() to avoid breaking any
existing callers that import start_patched directly. No monkey-patching
is performed by this module; the patching is handled inside the
server module via class injection.
"""

from a2a_adapter.server import main

if __name__ == "__main__":
    main()
