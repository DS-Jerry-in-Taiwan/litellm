"""
Unit tests for patch_metrics.py path resolver and patch idempotency.
Uses stdlib unittest + tempfile / unittest.mock; no litellm dependency.
"""
import os
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path


class TestResolveProxyServerPath(unittest.TestCase):
    """Tests for resolve_proxy_server_path() via os.path.exists / glob mocking."""

    def setUp(self):
        # Ensure patch_metrics is loaded (before any mock patches are applied)
        if "patch_metrics" not in sys.modules:
            sys.modules["patch_metrics"] = __import__(
                "patch_metrics",
                fromlist=["resolve_proxy_server_path", "get_proxy_server_candidates", "MODULE_LEVEL_CODE", "main"],
            )
        self.pm = sys.modules["patch_metrics"]

    @unittest.mock.patch("patch_metrics.os.path.exists")
    def test_resolver_picks_legacy_when_only_legacy_exists(self, mock_exists):
        """Legacy path exists; venv paths do not → resolver returns legacy."""
        mock_exists.side_effect = lambda p: p == "/app/litellm/proxy/proxy_server.py"

        result = self.pm.resolve_proxy_server_path()
        self.assertEqual(result, "/app/litellm/proxy/proxy_server.py")

    @unittest.mock.patch("patch_metrics.os.path.exists")
    def test_resolver_prefers_legacy_over_venv_when_both_exist(self, mock_exists):
        """Both legacy and venv exist → resolver returns legacy (search order)."""
        def exists(path):
            return path in (
                "/app/litellm/proxy/proxy_server.py",
                "/app/.venv/lib/python3.13/site-packages/litellm/proxy/proxy_server.py",
            )
        mock_exists.side_effect = exists

        result = self.pm.resolve_proxy_server_path()
        self.assertEqual(result, "/app/litellm/proxy/proxy_server.py")

    @unittest.mock.patch("patch_metrics.glob.glob")
    @unittest.mock.patch("patch_metrics.os.path.exists")
    def test_resolver_picks_venv_when_legacy_missing(self, mock_exists, mock_glob):
        """Legacy missing; venv exists → resolver returns venv path."""
        venv = "/app/.venv/lib/python3.13/site-packages/litellm/proxy/proxy_server.py"
        mock_glob.return_value = [venv]
        mock_exists.side_effect = lambda p: p == venv

        result = self.pm.resolve_proxy_server_path()
        self.assertEqual(result, venv)

    @unittest.mock.patch("patch_metrics.glob.glob")
    @unittest.mock.patch("patch_metrics.os.path.exists")
    def test_resolver_raises_file_not_found_lists_all_searched_paths(
        self, mock_exists, mock_glob
    ):
        """Neither legacy nor venv exist → FileNotFoundError with full path list."""
        venv_paths = [
            "/app/.venv/lib/python3.11/site-packages/litellm/proxy/proxy_server.py",
            "/app/.venv/lib/python3.12/site-packages/litellm/proxy/proxy_server.py",
            "/app/.venv/lib/python3.13/site-packages/litellm/proxy/proxy_server.py",
        ]
        mock_glob.return_value = venv_paths  # venv candidates exist per glob
        mock_exists.return_value = False      # but none pass os.path.exists

        with self.assertRaises(FileNotFoundError) as ctx:
            self.pm.resolve_proxy_server_path()

        error_msg = str(ctx.exception)
        # ALL candidate paths must appear in the error message
        self.assertIn("/app/litellm/proxy/proxy_server.py", error_msg)
        # Every venv candidate must be listed
        for vp in venv_paths:
            self.assertIn(vp, error_msg, f"{vp} must appear in error message")

    @unittest.mock.patch("patch_metrics.glob.glob")
    @unittest.mock.patch("patch_metrics.os.path.exists")
    def test_resolver_deterministic_across_multiple_venv_candidates(self, mock_exists, mock_glob):
        """Multiple venv candidates (python3.11, 3.12, 3.13); legacy missing → picks first alphabetically."""
        venv_paths = [
            "/app/.venv/lib/python3.11/site-packages/litellm/proxy/proxy_server.py",
            "/app/.venv/lib/python3.12/site-packages/litellm/proxy/proxy_server.py",
            "/app/.venv/lib/python3.13/site-packages/litellm/proxy/proxy_server.py",
        ]
        mock_glob.return_value = venv_paths  # glob returns in filesystem order
        mock_exists.side_effect = lambda p: p in venv_paths  # only venvs exist

        result = self.pm.resolve_proxy_server_path()
        # After sorted(glob.glob()), python3.11 should be first
        self.assertEqual(result, venv_paths[0])

    def test_get_proxy_server_candidates_includes_legacy_and_venv_glob(self):
        """get_proxy_server_candidates() returns a list with legacy + venv entries sorted."""
        candidates = self.pm.get_proxy_server_candidates()
        self.assertIsInstance(candidates, list)
        self.assertIn("/app/litellm/proxy/proxy_server.py", candidates)
        # venv entries must be sorted
        venv_candidates = [c for c in candidates if "/.venv/" in c]
        self.assertEqual(venv_candidates, sorted(venv_candidates))

    def test_resolver_does_not_import_litellm(self):
        """Resolver must not trigger litellm import (no package dependency)."""
        litellm_keys_before = {k for k in sys.modules if k.startswith("litellm")}
        # Force fresh import of patch_metrics
        mods_to_remove = [k for k in sys.modules if k.startswith("patch_metrics")]
        for m in mods_to_remove:
            del sys.modules[m]
        import patch_metrics  # noqa: F401
        _ = patch_metrics.get_proxy_server_candidates()
        litellm_keys_after = {k for k in sys.modules if k.startswith("litellm")}
        self.assertEqual(
            litellm_keys_before & litellm_keys_after,
            set(),
            "litellm must not be imported by patch_metrics resolver",
        )


class TestPatchIdempotency(unittest.TestCase):
    """Tests for MODULE_LEVEL_CODE patch idempotency using a real temp file."""

    def setUp(self):
        self._tmpdir = tempfile.mkdtemp(prefix="patch_metrics_test_")
        self._proxy_path = os.path.join(
            self._tmpdir,
            "app/.venv/lib/python3.13/site-packages/litellm/proxy/proxy_server.py",
        )
        Path(self._proxy_path).parent.mkdir(parents=True, exist_ok=True)
        Path(self._proxy_path).write_text("original content\n", encoding="utf-8")

    def tearDown(self):
        import shutil
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    @unittest.mock.patch("patch_metrics.glob.glob")
    @unittest.mock.patch("patch_metrics.os.path.exists")
    def test_marker_appears_once_after_two_main_calls(
        self, mock_exists, mock_glob
    ):
        """Calling main() twice must leave exactly one copy of the patch marker."""
        import patch_metrics

        marker = "# --- patch_metrics_route (module-level) ---"
        mock_glob.return_value = [self._proxy_path]
        mock_exists.side_effect = lambda p: p == self._proxy_path

        patch_metrics.main()
        content_after_first = Path(self._proxy_path).read_text(encoding="utf-8")
        self.assertEqual(
            content_after_first.count(marker), 1,
            "Marker should appear exactly once after first main()",
        )

        patch_metrics.main()
        content_after_second = Path(self._proxy_path).read_text(encoding="utf-8")
        self.assertEqual(
            content_after_second.count(marker), 1,
            "Marker should still appear exactly once after second main() (idempotent)",
        )

    @unittest.mock.patch("patch_metrics.glob.glob")
    @unittest.mock.patch("patch_metrics.os.path.exists")
    def test_original_content_preserved_after_patch(self, mock_exists, mock_glob):
        """Original file content (before marker) must be preserved after patching."""
        import patch_metrics

        mock_glob.return_value = [self._proxy_path]
        mock_exists.side_effect = lambda p: p == self._proxy_path

        patch_metrics.main()
        content = Path(self._proxy_path).read_text(encoding="utf-8")
        self.assertTrue(
            content.startswith("original content"),
            "Original content must be preserved at start of file",
        )


if __name__ == "__main__":
    unittest.main()
