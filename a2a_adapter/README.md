# A2A Adapter — Local Runtime

**What this is**: Project-owned A2A server wrapper that wraps `opencode-a2a`
v1.1.1 with a `PatchedOpencodeUpstreamClient` class injection, enabling
correct operation with OpenCode serve v1.17.13 (which returns an empty body
on `POST /session/{id}/message`). This is not a fork of opencode-a2a — it is
a thin adapter layer that sits in front of the stock upstream server.

**Status**: Phase 5 — local runtime packaging. The production A2A server on
`:8000` is **untouched**. This package provides a launchable local runtime for
development and testing only.

---

## Local Launch

Start the project-owned A2A server on the port configured via environment
(Defaults: `A2A_PORT=18001` when using the env template below):

```bash
cd /home/ubuntu/projects/litellm

# Using the env template:
cp a2a_adapter/.env.example a2a_adapter/.env
# Edit a2a_adapter/.env and set a real bearer token
#   python3 -c 'import secrets; print(secrets.token_hex(24))'

# Launch:
uv run --with opencode-a2a python -m a2a_adapter.server
```

The server will bind to `A2A_HOST:A2A_PORT` and connect to the upstream
OpenCode serve at `OPENCODE_BASE_URL` (default `http://127.0.0.1:4096`).

---

## Runtime Smoke Test

Run the smoke test to verify the server starts, serves the agent card and
health endpoints, and handles JSON-RPC correctly. The smoke test launches the
server on port **18001** (never 8000) and cleans up afterwards.

```bash
cd /home/ubuntu/projects/litellm
uv run --with opencode-a2a python -m a2a_adapter.runtime_smoke
```

Expected output: each check prints `PASS` or `FAIL` and the script exits 0 on
success.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `OPENCODE_BASE_URL` | `http://127.0.0.1:4096` | Upstream opencode serve URL |
| `A2A_HOST` | `127.0.0.1` | Bind host |
| `A2A_PORT` | `8000` | Bind port (use a non-privileged port in dev) |
| `A2A_PUBLIC_URL` | `http://127.0.0.1:8000` | Public URL advertised in agent card |
| `A2A_TASK_STORE_BACKEND` | `database` | `memory` or `database` |
| `A2A_LOG_LEVEL` | `WARNING` | Log level: DEBUG, INFO, WARNING, ERROR |
| `A2A_STATIC_AUTH_CREDENTIALS` | *(required)* | JSON array of auth credentials |

---

## Safety

### Port 8000 is production — do not replace without HITL

The production opencode-a2a server runs on **port 8000** and is the live
A2A endpoint for LiteLLM. The files in this package do **not** replace it.

To promote a project-owned server to port 8000 in production:
1. Obtain human-in-the-loop (HITL) approval
2. Test thoroughly on a non-production port first
3. Coordinate with the LiteLLM deployment team
4. Update `compose.yaml` and redeploy — do not hot-swap

**Until that approval is given, only use this package on non-8000 ports** (e.g.
18001) for local development and testing.

---

## Troubleshooting

### "Port already in use" when launching

Another process is using the target port. Change `A2A_PORT`:

```bash
A2A_PORT=18001 uv run --with opencode-a2a python -m a2a_adapter.server
```

### "UpstreamContractError" or empty responses from SendMessage

The upstream OpenCode serve at `OPENCODE_BASE_URL` is either:
1. Not running — start it: `opencode serve :4096`
2. Not reachable from the adapter — check network/ firewall
3. A version mismatch — this adapter targets OpenCode v1.17.13

### Server starts but health check fails with 401

The bearer token in `A2A_STATIC_AUTH_CREDENTIALS` does not match the
`Authorization` header sent by the client. Generate a fresh token:

```python
python3 -c 'import secrets; print(secrets.token_hex(24))'
```

Then update the env var and restart.

### Smoke test fails with "Server did not become ready"

The server took more than 15 seconds to start. Check:
- `opencode serve` is running on the upstream port
- There are no import errors: run `uv run --with opencode-a2a python -c "from a2a_adapter.server import main"`
- Port 18001 is not already in use

---

## End-to-End Test with LiteLLM

This test verifies the full chain from LiteLLM through to an actual LLM call:

```
test script → LiteLLM Proxy (:4000) → registered A2A agent
  → project-owned A2A server (:18002)
  → OpenCode serve (:4096)
  → LLM model
```

**Prerequisites:**
- LiteLLM Proxy running on `:4000` (with a valid model registered)
- OpenCode serve running on `:4096`

**Run:**
```bash
cd /home/ubuntu/projects/litellm
uv run --with opencode-a2a python -m a2a_adapter.test_litellm_e2e
```

The script:
1. Starts the project-owned A2A server on port **18002**
2. Registers it as an agent in LiteLLM
3. Sends a message through the LiteLLM A2A proxy
4. Verifies the actual LLM response
5. Cleans up: deletes the agent and stops the server

**Important:** The existing opencode-a2a on port 8000 is **not modified** or replaced by this test.

---

## File Reference

| File | Purpose |
|---|---|
| `a2a_adapter/server.py` | Official entrypoint (`create_app`, `main`) |
| `a2a_adapter/client.py` | `PatchedOpencodeUpstreamClient` class |
| `a2a_adapter/runtime_smoke.py` | Local smoke test (port 18001) |
| `a2a_adapter/.env.example` | Env var template (no real secrets) |
| `a2a_adapter/test_patch.py` | Unit tests for the patched client |
| `a2a_adapter/integration_test.py` | Three-phase flow test |
| `a2a_adapter/test_jsonrpc.py` | JSON-RPC E2E test (port 18000) |
| `a2a_adapter/start_patched.py` | Deprecated shim (re-exports `server.main`) |
| `a2a_adapter/patches.py` | Deprecated monkey-patch (do not use) |
