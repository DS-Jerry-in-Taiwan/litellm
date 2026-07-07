# LiteLLM Integration Guide — A2A Adapter (Class-Based)

**Document version**: 2.0 (Phase 4)
**Phase**: Phase 4 — Class-based Server Integration Refactor
**Last updated**: 2026-07-05

---

## Overview

This document describes how to integrate the OpenCode v1.17.13 compatibility
into a LiteLLM deployment that uses `opencode-a2a` as an A2A agent adapter.

### The Problem

OpenCode v1.17.13 (running on `:4096`) returns **HTTP 200 with an empty body**
from `POST /session/{id}/message`. The original `opencode-a2a` upstream client
expects a JSON body and raises `UpstreamContractError`, breaking all A2A
`SendMessage` operations.

### The Solution (Phase 4 — Class-Based)

Phase 4 replaces the runtime method monkey-patch (`apply_patch()`) with a
clean class-based approach:

1. **`a2a_adapter/client.py`** — defines `PatchedOpencodeUpstreamClient(OpencodeUpstreamClient)`
   which overrides `send_message()` to catch `UpstreamContractError` and return
   a minimal `OpencodeMessage`.
2. **`a2a_adapter/server.py`** — performs class injection before calling
   the upstream `create_app(settings)`, replacing `OpencodeUpstreamClient` with
   `PatchedOpencodeUpstreamClient` in the application module's namespace.

The monkey-patch approach (`patches.py` / `apply_patch()`) is **deprecated**.
The class-based approach is the recommended production path.

---

## Architecture

```
LiteLLM Proxy (:4000)         (optional, for agent registry)
         │
         └─→ External A2A clients
                   │
                   ▼
         opencode-a2a (:8000) ◄── PatchedOpencodeUpstreamClient injected at startup
                   │
                   ├─→ REST /v1/message:send   (opencode-a2a handles auth)
                   │
                   ├─→ JSON-RPC POST /          (SendMessage, etc.)
                   │
                   ▼
         opencode serve (:4096) ◄── PatchedOpencodeUpstreamClient.send_message talks to this
```

The patch is transparent to the A2A protocol layer. Both REST (`/v1/message:send`)
and JSON-RPC (`POST /`) routes pass through `ExecutionCoordinator.run()` which
calls `send_message()`. The subclass intercepts the empty-body error and recovers
gracefully.

---

## Architecture: How Class Injection Works

The key insight is that `create_app()` in `opencode_a2a.server.application`
uses a **module-level import** of `OpencodeUpstreamClient`:

```python
# opencode_a2a/server/application.py (upstream, cannot modify)
from ..opencode_upstream_client import OpencodeUpstreamClient  # module-level ref

def create_app(settings):
    upstream_client = OpencodeUpstreamClient(...)  # instance created here
```

By replacing `OpencodeUpstreamClient` in the module namespace **before** calling
`create_app()`, all instances created inside use our subclass:

```python
# a2a_adapter/server.py (our code)
from opencode_a2a.server import application as upstream_application
from a2a_adapter.client import PatchedOpencodeUpstreamClient

upstream_application.OpencodeUpstreamClient = PatchedOpencodeUpstreamClient
app = upstream_application.create_app(settings)  # uses our subclass
```

---

## Prerequisites

- `opencode-a2a` v1.1.1 installed (`uv tool install opencode-a2a`)
- `opencode serve` v1.17.13 running on `:4096`
- LiteLLM Proxy running on `:4000` (optional, for agent registry)
- Python 3.11+ with `uv` package manager
- `a2a_adapter/` from Phase 4 (class-based approach)

---

## Integration Steps

### 1. Start the Server (Class-Based Entrypoint)

The **recommended** production entrypoint is `a2a_adapter.server.main()`:

```bash
cd /home/ubuntu/projects/litellm
uv run --with opencode-a2a python -m a2a_adapter.server
```

Or programmatically:

```python
from a2a_adapter.server import main
main()  # blocking — runs uvicorn
```

This uses class injection (no monkey-patching).

### 2. Alternative: Direct Client Usage

If you need the client directly (not via the server):

```python
from a2a_adapter.client import PatchedOpencodeUpstreamClient
from opencode_a2a.config import Settings, StaticAuthCredentialSettings

settings = Settings(
    opencode_base_url="http://127.0.0.1:4096",
    a2a_static_auth_credentials=[
        StaticAuthCredentialSettings(
            scheme="bearer",
            principal="agent",
            token="<token>",
        )
    ],
)
client = PatchedOpencodeUpstreamClient(settings)
# Use client.send_message() — handles v1.17.13 empty body automatically
```

### 3. Environment Configuration

| Variable | Default | Description |
|---|---|---|
| `OPENCODE_BASE_URL` | `http://127.0.0.1:4096` | Upstream opencode serve URL |
| `A2A_HOST` | `127.0.0.1` | Bind host |
| `A2A_PORT` | `8000` | Bind port |
| `A2A_PUBLIC_URL` | `http://127.0.0.1:8000` | Public URL in agent card |
| `A2A_TASK_STORE_BACKEND` | `database` | `memory` or `database` |
| `A2A_TASK_STORE_DATABASE_URL` | `sqlite+aiosqlite:///./opencode-a2a.db` | SQLAlchemy DB URL |
| `A2A_LOG_LEVEL` | `WARNING` | Log level (DEBUG, INFO, WARNING, ERROR) |
| `A2A_STATIC_AUTH_CREDENTIALS` | **required** | JSON array of auth credentials |

### 4. Authentication Credentials

The server requires at least one enabled authentication credential. Use bearer
or basic auth:

```bash
# Generate a secure token
DEMO_BEARER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"

# Minimal production configuration
export OPENCODE_BASE_URL="http://127.0.0.1:4096"
export A2A_PORT="8000"
export A2A_STATIC_AUTH_CREDENTIALS='[{"scheme":"bearer","token":"'"${DEMO_BEARER_TOKEN}"'","principal":"litellm-agent"}]'
```

For **production**, use a real credential manager (e.g., AWS Secrets Manager,
HashiCorp Vault) to inject `A2A_STATIC_AUTH_CREDENTIALS`. Never commit tokens
to source control.

### 5. LiteLLM Agent Registration (Optional)

LiteLLM Proxy can act as an agent registry. To register the opencode-a2a
agent:

```bash
curl -X POST http://localhost:4000/agent \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "agent_name": "opencode-a2a",
    "agent_type": "a2a",
    "agent_metadata": {
      "a2a_url": "http://localhost:8000",
      "auth_scheme": "bearer",
      "description": "OpenCode A2A agent adapter"
    }
  }'
```

### 6. Verifying the Integration

Run the Phase 4 end-to-end test:

```bash
cd /home/ubuntu/projects/litellm
uv run --with opencode-a2a python -m a2a_adapter.test_patch
uv run --with opencode-a2a python -m a2a_adapter.integration_test
uv run --with opencode-a2a python -m a2a_adapter.test_jsonrpc
```

All three tests should exit with code 0.

---

## Migration from Monkey-Patch (patches.py)

If you are currently using `apply_patch()`:

```python
# OLD (deprecated monkey-patch approach)
from a2a_adapter.patches import apply_patch
apply_patch()
from opencode_a2a.server.application import main
main()
```

Replace with:

```python
# NEW (class-based approach — preferred)
from a2a_adapter.server import main
main()
```

Or for direct client usage:

```python
# OLD (deprecated)
from opencode_a2a.opencode_upstream_client import OpencodeUpstreamClient
from a2a_adapter.patches import apply_patch
apply_patch()
client = OpencodeUpstreamClient(settings)

# NEW (class-based)
from a2a_adapter.client import PatchedOpencodeUpstreamClient
client = PatchedOpencodeUpstreamClient(settings)
```

---

## File Reference

### Official Entry Points (Phase 4)

| File | Purpose |
|---|---|
| `a2a_adapter/server.py` | Official server entrypoint with class injection (`create_app`, `main`) |
| `a2a_adapter/client.py` | `PatchedOpencodeUpstreamClient` — class-based upstream client |
| `a2a_adapter/start_patched.py` | Deprecated backward-compatible shim (re-exports `server.main`) |

### Deprecated (Backward Compatibility Only)

| File | Purpose |
|---|---|
| `a2a_adapter/patches.py` | Deprecated monkey-patch (`apply_patch`/`remove_patch`) — do not use in new code |

### Tests

| File | Purpose |
|---|---|
| `a2a_adapter/test_patch.py` | Unit tests for `PatchedOpencodeUpstreamClient` |
| `a2a_adapter/integration_test.py` | Three-phase flow test |
| `a2a_adapter/test_jsonrpc.py` | JSON-RPC end-to-end test |

### Phase Handoffs

| File | Purpose |
|---|---|
| `docs/agent_context/a2a_adapter_redesign/phase1/phase1_handoff.md` | Phase 1 results (patch design) |
| `docs/agent_context/a2a_adapter_redesign/phase2/phase2_handoff.md` | Phase 2 results (integration test + startup wrapper) |
| `docs/agent_context/a2a_adapter_redesign/phase3/phase3_handoff.md` | Phase 3 results (JSON-RPC test) |
| `docs/agent_context/a2a_adapter_redesign/phase4/phase4_handoff.md` | Phase 4 results (class-based refactor — this phase) |

---

## Session Binding (A2A Extensions)

The opencode-a2a server uses the **A2A session binding extension** to correlate
A2A sessions with upstream OpenCode sessions.

### How It Works

1. Client includes `A2A-Extensions: urn:opencode-a2a:extension:session-binding:v1` header
2. Client includes session ID in `metadata.shared.session.id` in the request
3. `ExecutionCoordinator` binds the A2A task to the upstream session
4. Subsequent requests with the same session ID are routed to the same upstream session

### Example: JSON-RPC SendMessage with Session Binding

```json
POST / HTTP/1.1
Host: localhost:8000
Content-Type: application/json
Authorization: Bearer <token>
A2A-Extensions: urn:opencode-a2a:extension:session-binding:v1

{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "SendMessage",
  "params": {
    "message": {
      "role": "user",
      "parts": [{"type": "text", "text": "Hello"}]
    },
    "configuration": {
      "returnImmediately": false
    },
    "metadata": {
      "shared": {
        "session": {
          "id": "ses_abc123..."
        }
      }
    }
  }
}
```

---

## Troubleshooting

### Server returns 401 Unauthorized

Check `A2A_STATIC_AUTH_CREDENTIALS` is correctly set and the
`Authorization` header matches one of the configured credentials.

### Port 8000 already in use

Set `A2A_PORT` to a different value:
```bash
export A2A_PORT=8001
```

---

## Phase 5 — Local Runtime Launch

Phase 5 packages `a2a_adapter/` as a self-contained local runtime with a smoke
test and environment template.

### Environment Template

A template for local development is available:

```bash
cp a2a_adapter/.env.example a2a_adapter/.env
# Edit .env — set A2A_STATIC_AUTH_CREDENTIALS with a real generated token:
#   python3 -c 'import secrets; print(secrets.token_hex(24))'
```

### Local Launch

```bash
cd /home/ubuntu/projects/litellm
uv run --with opencode-a2a python -m a2a_adapter.server
```

The server will bind to `A2A_HOST:A2A_PORT` (default `127.0.0.1:18001` per the
`.env.example`). It requires the upstream OpenCode serve on `OPENCODE_BASE_URL`
(default `http://127.0.0.1:4096`) to be running.

### Runtime Smoke Test

```bash
cd /home/ubuntu/projects/litellm
uv run --with opencode-a2a python -m a2a_adapter.runtime_smoke
```

This launches the server on port **18001** (never 8000), runs a quick check
suite (agent card, health, JSON-RPC, invalid method), and cleanly shuts down.
Exit code 0 means all checks passed.

### Port 8000 is Production — Do Not Replace Without HITL

The existing opencode-a2a server on **port 8000** is the live A2A endpoint for
LiteLLM. Phase 5 does **not** replace it. Replacing port 8000 requires
explicit human-in-the-loop (HITL) approval and coordination with the LiteLLM
deployment team.

---

## Phase 6 — LiteLLM E2E Integration

Phase 6 validates the full end-to-end chain:

```
test script → LiteLLM Proxy (:4000) → registered A2A agent
  → project-owned A2A server (:18002)
  → OpenCode serve (:4096)
  → LLM model (e.g., DeepSeek V4)
```

### Architecture

LiteLLM natively supports A2A agents through two endpoints:

| Endpoint | Purpose |
|---|---|
| `POST /v1/agents` | Register a new A2A agent with its AgentCard |
| `POST /a2a/{agent_id}/message/send` | Proxy an A2A message to the registered agent |

When a message is sent to `/a2a/{agent_id}/message/send`, LiteLLM forwards the
JSON-RPC request to the agent's URL (from the AgentCard) using any configured
`static_headers` for authentication. The response is proxied back to the caller.

### Registration Example

```bash
curl -X POST "http://localhost:4000/v1/agents" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "agent_name": "my-agent",
    "agent_card_params": {
      "name": "My Agent",
      "description": "Agent connected to OpenCode",
      "url": "http://127.0.0.1:18002",
      "version": "1.0.0",
      "protocolVersion": "1.0",
      "capabilities": {"streaming": true},
      "defaultInputModes": ["text"],
      "defaultOutputModes": ["text"],
      "skills": [{"id": "opencode.chat", "name": "OpenCode Chat", "description": "...", "tags": ["test"]}]
    },
    "static_headers": {
      "Authorization": "Bearer <your-a2a-server-token>"
    }
  }'
```

### Send Message Example

```bash
curl -X POST "http://localhost:4000/a2a/my-agent/message/send" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "A2A-Extensions: urn:opencode-a2a:extension:session-binding:v1" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "SendMessage",
    "params": {
      "message": {
        "role": "user",
        "parts": [{"type": "text", "text": "Hello"}]
      }
    }
  }'
```

### E2E Test

A self-contained test script automates the full flow:

```bash
cd /home/ubuntu/projects/litellm
uv run --with opencode-a2a python -m a2a_adapter.test_litellm_e2e
```

### Known Limitation

The existing opencode-a2a server on port 8000 uses the **stock upstream client**
which does NOT handle the OpenCode v1.17.13 empty-body response.
SendMessage calls through port 8000 return `TASK_STATE_FAILED`.
The project-owned server (with `PatchedOpencodeUpstreamClient`) is the only one
that correctly completes A2A message flows.

---

## Security Considerations

1. **Never commit real credentials** to source control. Use secret managers.
2. **Do not expose `A2A_STATIC_AUTH_CREDENTIALS`** in container images.
   Inject via environment variables at runtime.
3. **LiteLLM proxy** should sit behind TLS in production. Do not expose `:4000`
   or `:8000` directly to the internet.
4. **Session binding** allows any authenticated client to send messages to any
   session. Use appropriate access control at the LiteLLM layer.
