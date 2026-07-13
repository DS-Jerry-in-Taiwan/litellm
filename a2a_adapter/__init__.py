"""
a2a_adapter — OpenCode A2A compatibility adapter for LiteLLM.

Public exports
-------------
PatchedOpencodeUpstreamClient  : subclass of OpencodeUpstreamClient with v1.17.13 fix
create_app(settings)           : build FastAPI app with patched client injected
main()                         : official server entrypoint (blocking uvicorn.run)

Migration from patches.py
-------------------------
Old (deprecated monkey-patch):
    from a2a_adapter.patches import apply_patch
    apply_patch()

New (class-based, preferred):
    from a2a_adapter.client import PatchedOpencodeUpstreamClient
    # Use directly:
    client = PatchedOpencodeUpstreamClient(settings)
    # Or via server entrypoint:
    from a2a_adapter.server import main
    main()
"""

from a2a_adapter.client import PatchedOpencodeUpstreamClient
from a2a_adapter.server import create_app, main
