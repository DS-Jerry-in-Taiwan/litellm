from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_ecs_runtime_uses_litellm_root_path() -> None:
    ecs = (ROOT / "deploy/aws/company-existing/ecs.tf").read_text()

    assert 'name  = "SERVER_ROOT_PATH"' in ecs
    assert 'value = "/litellm"' in ecs


def test_local_runtime_defaults_to_same_root_path() -> None:
    compose = (ROOT / "compose.yaml").read_text()
    env_example = (ROOT / ".env.example").read_text()

    assert "SERVER_ROOT_PATH=${SERVER_ROOT_PATH:-/litellm}" in compose
    assert "SERVER_ROOT_PATH=/litellm" in env_example
