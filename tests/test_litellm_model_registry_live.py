"""Live Admin API regression evidence for the scoped model alias mutation.

This test authenticates to the local LiteLLM Admin API using ``LITELLM_MASTER_KEY``
from the process environment and verifies that the source-of-truth payload in
``scripts.litellm_model_registry`` matches the live DB-managed record.  It also
re-runs the scoped ``upsert_models`` path to prove that exactly one
``PATCH /model/{uuid}/update`` is issued, no ``POST /model/new`` is issued, and
no credential or unrelated-model endpoint is touched.

The test is skipped when ``LITELLM_MASTER_KEY`` is absent, so it remains safe
for CI environments that do not have a running LiteLLM proxy.  Secrets are never
printed: the recording wrapper stores only HTTP methods, paths, and model
payloads (which contain no API keys).
"""

from __future__ import annotations

import os
import unittest
from typing import Any

from scripts import litellm_model_registry as registry


class _RecordingClient(registry.LiteLLMAdminClient):
    """LiteLLMAdminClient that records every Admin API call it makes."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.calls: list[tuple[str, str, dict[str, Any] | None]] = []

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None, timeout: int = 120) -> Any:  # noqa: D102
        self.calls.append((method, path, payload))
        return super().request(method, path, payload, timeout)


@unittest.skipUnless(
    bool(os.environ.get("LITELLM_MASTER_KEY", "").strip()),
    "LITELLM_MASTER_KEY not present; live Admin API evidence skipped",
)
class LiveScopedMutationTest(unittest.TestCase):
    """Authenticated live evidence for the agent-developer-primary switch."""

    @classmethod
    def setUpClass(cls) -> None:
        base_url = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000").rstrip("/")
        master_key = os.environ["LITELLM_MASTER_KEY"].strip()
        cls.client = _RecordingClient(base_url, master_key)
        cls.primary_alias = "agent-developer-primary"
        cls.fallback_alias = "agent-developer-fallback"

    def _find_records(self, alias: str) -> list[dict[str, Any]]:
        return [m for m in self.client.model_info() if m.get("model_name") == alias]

    def _projection(self, record: dict[str, Any]) -> dict[str, Any]:
        params = record.get("litellm_params", {})
        info = record.get("model_info", {})
        return {
            "model_name": record.get("model_name"),
            "litellm_params.model": params.get("model"),
            "litellm_params.api_base": params.get("api_base"),
            "litellm_params.litellm_credential_name": params.get("litellm_credential_name"),
            "model_info.mode": info.get("mode"),
        }

    def _source_projection(self, spec: registry.ModelSpec) -> dict[str, Any]:
        payload = registry.model_payload(spec)
        params = payload["litellm_params"]
        return {
            "model_name": payload["model_name"],
            "litellm_params.model": params["model"],
            "litellm_params.api_base": params.get("api_base"),
            "litellm_params.litellm_credential_name": params.get("litellm_credential_name"),
            "model_info.mode": payload["model_info"]["mode"],
        }

    def test_live_primary_is_singleton(self) -> None:
        records = self._find_records(self.primary_alias)
        self.assertEqual(len(records), 1, f"expected exactly one {self.primary_alias} record")

    def test_live_primary_matches_source_payload(self) -> None:
        records = self._find_records(self.primary_alias)
        self.assertEqual(len(records), 1)
        spec = next(s for s in registry.MODELS if s.alias == self.primary_alias)
        self.assertEqual(self._projection(records[0]), self._source_projection(spec))

    def test_old_routes_absent_from_live_primary(self) -> None:
        records = self._find_records(self.primary_alias)
        self.assertEqual(len(records), 1)
        text = str(records[0])
        self.assertNotIn("chatgpt/gpt-5.6-sol", text)
        self.assertNotIn("openai/minimax-m2.7", text)

    def test_live_fallback_unchanged(self) -> None:
        records = self._find_records(self.fallback_alias)
        self.assertEqual(len(records), 1)
        spec = next(s for s in registry.MODELS if s.alias == self.fallback_alias)
        self.assertEqual(self._projection(records[0]), self._source_projection(spec))

    def test_scoped_upsert_is_exactly_one_patch_zero_create(self) -> None:
        """Re-run the scoped upsert and inspect the Admin API traffic it generates."""
        before = self._find_records(self.primary_alias)
        self.assertEqual(len(before), 1)
        uuid_before = before[0]["model_info"]["id"]
        self.assertTrue(uuid_before)

        primary_spec = next(s for s in registry.MODELS if s.alias == self.primary_alias)

        # Snapshot call count so earlier read-only tests do not dilute this audit.
        calls_before = len(self.client.calls)

        # Replay the exact scoped write path the registry script uses.
        registry.upsert_models(self.client, [primary_spec], dry_run=False)

        # Re-query live state inside the same audit window.
        after = self._find_records(self.primary_alias)

        # Separate the mutating Admin API calls made during this upsert.
        new_calls = self.client.calls[calls_before:]
        model_write_calls = [
            (method, path, payload)
            for method, path, payload in new_calls
            if path.startswith("/model") and method in ("PATCH", "POST")
        ]
        patch_calls = [c for c in model_write_calls if c[0] == "PATCH"]
        post_calls = [c for c in model_write_calls if c[0] == "POST"]
        credential_calls = [c for c in new_calls if c[1].startswith("/credentials")]

        self.assertEqual(
            len(model_write_calls),
            1,
            f"expected exactly one model write call, got {len(model_write_calls)}",
        )
        self.assertEqual(
            len(patch_calls),
            1,
            f"expected exactly one PATCH, got {len(patch_calls)}",
        )
        self.assertEqual(
            len(post_calls),
            0,
            f"expected zero POST /model/new calls, got {len(post_calls)}",
        )
        self.assertEqual(
            len(credential_calls),
            0,
            f"expected zero credential calls, got {len(credential_calls)}",
        )

        expected_path = f"/model/{uuid_before}/update"
        self.assertEqual(
            patch_calls[0][1],
            expected_path,
            "PATCH must target the existing primary UUID",
        )

        # The PATCH payload must be the exact source payload for the primary alias.
        self.assertEqual(
            patch_calls[0][2],
            registry.model_payload(primary_spec),
            "PATCH payload must equal model_payload(primary_spec)",
        )

        # No unrelated alias may appear in any write call.
        for method, path, payload in new_calls:
            if method in ("PATCH", "POST") and payload:
                payload_alias = payload.get("model_name")
                if payload_alias and payload_alias != self.primary_alias:
                    self.fail(f"unrelated alias touched: {payload_alias}")

        # Confirm the UUID is unchanged and fields still match after the PATCH.
        self.assertEqual(len(after), 1)
        self.assertEqual(
            after[0]["model_info"]["id"],
            uuid_before,
            "primary UUID must remain unchanged after idempotent PATCH",
        )
        self.assertEqual(
            self._projection(after[0]),
            self._source_projection(primary_spec),
        )


if __name__ == "__main__":
    unittest.main()
