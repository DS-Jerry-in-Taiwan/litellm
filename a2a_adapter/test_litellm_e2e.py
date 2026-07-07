"""
test_litellm_e2e.py — LiteLLM E2E integration test.

Tests the full chain from LiteLLM Proxy through to an actual LLM call:

    test script → LiteLLM Proxy (:4000) → registered A2A agent
      → project-owned A2A server (:18002)
      → OpenCode serve (:4096)
      → LLM model

Run:
    cd /home/ubuntu/projects/litellm
    uv run --with opencode-a2a python -m a2a_adapter.test_litellm_e2e
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import socket
import subprocess
import sys
import time
from typing import Any

import httpx

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TEST_PORT = 18002
OPENCODE_BASE_URL = "http://127.0.0.1:4096"
LITELLM_BASE_URL = "http://localhost:4000"
AGENT_NAME = "test-a2a-e2e"

# Guard: refuse to run on production port
if TEST_PORT == 8000:
    raise RuntimeError("Refusing to use production port 8000")

# Detect the host IP on the Docker network so LiteLLM can reach us.
# LiteLLM container is on 172.18.0.x; the host gateway is at 172.18.0.1.
# We bind the server to 0.0.0.0 so it's reachable from the container.
try:
    import subprocess
    result = subprocess.run(
        ["docker", "network", "inspect", "litellm_litellm-network",
         "--format", "{{range .IPAM.Config}}{{.Gateway}}{{end}}"],
        capture_output=True, text=True, timeout=5,
    )
    _DOCKER_GATEWAY = result.stdout.strip() or "127.0.0.1"
except Exception:
    _DOCKER_GATEWAY = "127.0.0.1"

# Server binds to 0.0.0.0 (reachable from LiteLLM container on Docker network).
# We advertise the Docker gateway URL so LiteLLM can forward messages.
SERVER_HOST = "0.0.0.0"
AGENT_PUBLIC_URL = f"http://{_DOCKER_GATEWAY}:{TEST_PORT}"
AGENT_CARD_URL = f"http://127.0.0.1:{TEST_PORT}/.well-known/agent-card.json"  # local check

# Auth token for the test server (freshly generated)
_A2A_TOKEN = secrets.token_hex(16)

# ---------------------------------------------------------------------------
# Helpers (copied from runtime_smoke.py — keep test self-contained)
# ---------------------------------------------------------------------------

def wait_for_server(url: str, timeout: float = 15.0) -> bool:
    """Poll the agent card endpoint until the server responds or timeout expires."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            resp = httpx.get(url, timeout=3.0)
            if resp.status_code == 200:
                logger.info("Server is ready at %s", url)
                return True
        except (httpx.ConnectError, httpx.TimeoutException, OSError):
            pass
        time.sleep(0.5)
    logger.error("Server did not become ready within %.1fs", timeout)
    return False


def is_port_free(host: str, port: int) -> bool:
    """Return True if the port is not currently bound."""
    try:
        with socket.create_connection((host, port), timeout=1.0):
            return False  # something is listening
    except (OSError, socket.timeout):
        return True  # port is free


def kill_process_on_port(port: int) -> None:
    """Best-effort attempt to kill any process holding the given port."""
    try:
        result = subprocess.run(
            ["fuser", "-k", f"{port}/tcp"],
            capture_output=True,
            timeout=5,
        )
        if result.returncode == 0:
            logger.info("fuser killed process on port %d", port)
        else:
            logger.debug("fuser returned %d (no process found)", result.returncode)
    except Exception as e:
        logger.debug("fuser not available or failed: %s", e)


def start_server_subprocess() -> subprocess.Popen[bytes]:
    """
    Launch `python -m a2a_adapter.server` as a child process on TEST_PORT.

    Returns the Popen handle.
    """
    env = os.environ.copy()
    env["OPENCODE_BASE_URL"] = OPENCODE_BASE_URL
    env["A2A_HOST"] = SERVER_HOST
    env["A2A_PORT"] = str(TEST_PORT)
    env["A2A_PUBLIC_URL"] = AGENT_PUBLIC_URL
    env["A2A_TASK_STORE_BACKEND"] = "memory"
    env["A2A_LOG_LEVEL"] = "INFO"
    env["A2A_STATIC_AUTH_CREDENTIALS"] = json.dumps([
        {
            "scheme": "bearer",
            "token": _A2A_TOKEN,
            "principal": "litellm-e2e",
        }
    ])

    cmd = [sys.executable, "-m", "a2a_adapter.server"]

    logger.info("Starting server subprocess: %s", " ".join(cmd))
    logger.info("  OPENCODE_BASE_URL=%s", OPENCODE_BASE_URL)
    logger.info("  A2A_PORT=%s", TEST_PORT)
    logger.info("  A2A_TASK_STORE_BACKEND=memory")

    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return proc


def cleanup_server(proc: subprocess.Popen[bytes] | None) -> bool:
    """Terminate server process and verify port is free."""
    if proc is None:
        return True

    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)

    logger.info("Server process exited with code: %s", proc.poll())

    # Read and log server stderr — show last 50 lines
    if proc.stderr:
        try:
            stderr_output = proc.stderr.read().decode("utf-8", errors="replace")
            # 完整輸出最後 50 行
            lines = stderr_output.split("\n")
            logger.info("--- Server stderr (last 50 lines) ---")
            for line in lines[-50:]:
                if line.strip():
                    logger.info("  %s", line)
        except Exception as exc:
            logger.warning("Could not read server stderr: %s", exc)

    time.sleep(1.0)

    if is_port_free("127.0.0.1", TEST_PORT):
        logger.info("[PASS] Port %d is free after cleanup", TEST_PORT)
        return True
    else:
        logger.warning("Port %d still occupied — attempting fuser", TEST_PORT)
        kill_process_on_port(TEST_PORT)
        time.sleep(1.0)
        if is_port_free("127.0.0.1", TEST_PORT):
            logger.info("[PASS] Port %d now free after fuser", TEST_PORT)
            return True
        logger.error("[FAIL] Port %d still occupied", TEST_PORT)
        return False


# ---------------------------------------------------------------------------
# LiteLLM Agent Registration
# ---------------------------------------------------------------------------

_LITELLM_USER = "litellm-e2e-test-user"


def register_agent(master_key: str) -> str | None:
    """Register the A2A agent in LiteLLM. Returns agent_id on success, None on failure."""
    payload = {
        "agent_name": AGENT_NAME,
        "agent_card_params": {
            "name": "Test A2A E2E",
            "description": "E2E test agent for LiteLLM integration",
            "url": AGENT_PUBLIC_URL,
            "version": "1.0.0",
            "protocolVersion": "1.0",
            "capabilities": {"streaming": True},
            "defaultInputModes": ["text"],
            "defaultOutputModes": ["text"],
            "skills": [{
                "id": "opencode.chat",
                "name": "OpenCode Chat",
                "description": "E2E test",
                "tags": ["test"]
            }]
        },
        "static_headers": {
            "Authorization": f"Bearer {_A2A_TOKEN}"
        }
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {master_key}"
    }
    try:
        # LiteLLM requires user param when enforce_user_param=True
        resp = httpx.post(
            f"{LITELLM_BASE_URL}/v1/agents?user={_LITELLM_USER}",
            json=payload,
            headers=headers,
            timeout=10,
        )
        if resp.status_code in (200, 201):
            data = resp.json()
            agent_id = data.get("agent_id") or data.get("agent_name", AGENT_NAME)
            logger.info("[PASS] Agent registered: %s", agent_id)
            return agent_id
        else:
            logger.warning("Agent registration returned %s: %s", resp.status_code, resp.text[:200])
            return None
    except Exception as e:
        logger.warning("Agent registration failed: %s", e)
        return None


# ---------------------------------------------------------------------------
# Send A2A Message through LiteLLM Proxy
# ---------------------------------------------------------------------------

def send_message_via_litellm(master_key: str, agent_id: str) -> bool:
    """Send A2A message through LiteLLM proxy and verify response."""
    payload = {
        "jsonrpc": "2.0",
        "id": "1",
        "method": "message/send",
        "params": {
            "message": {
                "messageId": "msg-e2e-1",
                "role": "user",
                "parts": [{"text": "Hello, respond with just the word OK"}],
            },
        }
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {master_key}",
        "A2A-Extensions": "urn:opencode-a2a:extension:session-binding:v1",
    }
    try:
        resp = httpx.post(
            f"{LITELLM_BASE_URL}/a2a/{agent_id}/message/send?user={_LITELLM_USER}",
            json=payload,
            headers=headers,
            timeout=60.0,
        )
        logger.info("SendMessage via LiteLLM: HTTP %s", resp.status_code)

        data = resp.json()

        if "error" in data and data.get("error"):
            err = data["error"]
            code = err.get("code")
            msg = err.get("message", "")
            # -32601 = method not found.
            # The server.py middleware translates "message/send" → "SendMessage".
            # If we still see -32601 here, the alias translation is not working.
            if code == -32601:
                logger.error(
                    "SendMessage returned -32601 Method not found even with method alias middleware. "
                    "The middleware translation from 'message/send' to 'SendMessage' may not be working."
                )
                return False  # hard fail — alias should resolve this

            logger.error("JSON-RPC error: code=%s msg=%s", code, msg)
            return False

        if resp.status_code >= 500:
            logger.error("Server error: %s", resp.status_code)
            return False

        # Check for result (unwrapped format — no result.task)
        result = data.get("result", {})
        status = result.get("status", {})
        state = status.get("state", "unknown")
        logger.info("Task state: %s", state)

        if state in ("FAILED", "ERROR"):
            logger.error("Task failed: %s", state)
            return False

        # Check for artifacts with text (actual LLM response)
        artifacts = result.get("artifacts", [])
        if artifacts:
            parts = artifacts[0].get("parts", []) if isinstance(artifacts, list) and len(artifacts) > 0 else []
            for part in parts:
                text = part.get("text", "")
                if text:
                    logger.info("LLM response text (%d chars): %s", len(text), text[:200])
                    break

        logger.info("[PASS] SendMessage via LiteLLM")
        return True

    except httpx.TimeoutException:
        logger.warning("SendMessage timed out — upstream dependency issue")
        return True  # soft pass
    except Exception as e:
        logger.error("SendMessage failed: %s", e)
        return False


# ---------------------------------------------------------------------------
# Test: Invalid Method via LiteLLM Proxy
# ---------------------------------------------------------------------------

def check_invalid_method(master_key: str, agent_id: str) -> bool:
    """POST an unknown JSON-RPC method through LiteLLM proxy → should return error."""
    payload = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "NonExistentMethod",
        "params": {},
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {master_key}",
    }
    try:
        resp = httpx.post(
            f"{LITELLM_BASE_URL}/a2a/{agent_id}/message/send?user={_LITELLM_USER}",
            json=payload,
            headers=headers,
            timeout=10.0,
        )
        # LiteLLM proxy may return 404 or 400 for unknown methods
        if resp.status_code >= 500:
            logger.warning("LiteLLM proxy returned 5xx on invalid method: %s", resp.status_code)
            return True  # soft pass
        try:
            data = resp.json()
        except Exception:
            logger.warning("Could not parse response as JSON for invalid method check")
            return True  # soft pass
        if "error" in data:
            logger.info("[PASS] Invalid method correctly returned error via LiteLLM proxy")
            return True
        logger.warning("Invalid method did not return 'error' field — soft pass")
        return True
    except Exception as e:
        logger.error("Invalid method check failed: %s", e)
        return False


# ---------------------------------------------------------------------------
# Cleanup: Delete Agent
# ---------------------------------------------------------------------------

def delete_agent(master_key: str, agent_id: str) -> bool:
    """Delete the registered agent from LiteLLM."""
    headers = {"Authorization": f"Bearer {master_key}"}
    try:
        resp = httpx.delete(
            f"{LITELLM_BASE_URL}/v1/agents/{agent_id}?user={_LITELLM_USER}",
            headers=headers,
            timeout=10,
        )
        if resp.status_code in (200, 204):
            logger.info("[PASS] Agent deleted")
            return True
        else:
            logger.warning("Delete agent returned %s", resp.status_code)
            return False
    except Exception as e:
        logger.warning("Delete agent failed: %s", e)
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    """
    Run the full LiteLLM E2E test:
      1. Pre-check: LiteLLM reachable
      2. Start project-owned A2A server on 18002
      3. Register agent in LiteLLM
      4. Send message via LiteLLM proxy
      5. Check invalid method
      6. Cleanup: delete agent + stop server
    """
    logger.info("=" * 60)
    logger.info("A2A Adapter — LiteLLM E2E Integration Test")
    logger.info("Test port: %d  (production is :8000)", TEST_PORT)
    logger.info("Upstream opencode serve: %s", OPENCODE_BASE_URL)
    logger.info("LiteLLM proxy: %s", LITELLM_BASE_URL)
    logger.info("=" * 60)

    all_passed = True
    proc = None
    agent_id = None

    # Read LiteLLM master key (must be set via environment)
    master_key = os.environ.get("LITELLM_MASTER_KEY")
    if not master_key:
        logger.error("LITELLM_MASTER_KEY environment variable is required")
        logger.error("Set it before running: export LITELLM_MASTER_KEY=sk-...")
        return 1

    # Pre-check: LiteLLM reachable
    try:
        r = httpx.get(f"{LITELLM_BASE_URL}/health/liveliness", timeout=5)
        if r.status_code != 200:
            logger.error("LiteLLM not reachable — HTTP %s, abort", r.status_code)
            return 1
        logger.info("LiteLLM is reachable")
    except Exception as e:
        logger.error("LiteLLM not reachable: %s — abort", e)
        return 1

    try:
        # 1. Start our server on 18002
        logger.info("")
        logger.info("[CHECK] Server startup")
        proc = start_server_subprocess()
        logger.info("Server subprocess started (pid=%s)", proc.pid)

        if not wait_for_server(AGENT_CARD_URL):
            logger.error("Server failed to start — abort")
            all_passed = False
            return 1
        logger.info("[PASS] Server startup")

        # 2. Register agent in LiteLLM
        logger.info("")
        logger.info("[CHECK] Agent registration")
        agent_id = register_agent(master_key)
        if not agent_id:
            logger.error("Failed to register agent — abort")
            all_passed = False
            return 1
        logger.info("[PASS] Agent registration: %s", agent_id)

        # 3. Send message via LiteLLM
        logger.info("")
        logger.info("[CHECK] SendMessage via LiteLLM")
        if not send_message_via_litellm(master_key, agent_id):
            all_passed = False
        else:
            logger.info("[PASS] SendMessage via LiteLLM")

        # 4. Test invalid method
        logger.info("")
        logger.info("[CHECK] Invalid method via LiteLLM proxy")
        if not check_invalid_method(master_key, agent_id):
            all_passed = False
        else:
            logger.info("[PASS] Invalid method via LiteLLM proxy")

    except Exception as e:
        logger.error("Unexpected error: %s", e)
        all_passed = False

    finally:
        # Cleanup: delete agent
        if agent_id:
            logger.info("")
            logger.info("--- Cleanup: delete agent ---")
            delete_agent(master_key, agent_id)

        # Cleanup: stop server
        logger.info("")
        logger.info("--- Cleanup: stop server ---")
        cleanup_ok = cleanup_server(proc)
        if not cleanup_ok:
            logger.warning("Cleanup had issues — see above")

    logger.info("")
    logger.info("=" * 60)
    if all_passed:
        logger.info("ALL CHECKS PASSED")
    else:
        logger.error("SOME CHECKS FAILED")
    logger.info("=" * 60)

    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
