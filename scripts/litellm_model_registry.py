#!/usr/bin/env python3
"""Centralized LiteLLM credential/model registry bootstrapper.

This script replays the DB-managed LiteLLM provider setup used by this
deployment-template repo. It is intended for:

- migration to a fresh LiteLLM DB
- provider API key rotation
- restoring model aliases after a DB reset

Secrets are read from an env file or the process environment and are never
printed. The script talks to LiteLLM Admin API using LITELLM_MASTER_KEY.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = "http://localhost:4000"


@dataclass(frozen=True)
class CredentialSpec:
    name: str
    provider: str
    env_var: str
    description: str


@dataclass(frozen=True)
class ModelSpec:
    alias: str
    route_model: str
    credential_name: str
    description: str
    api_base: str | None = None
    smoke_max_tokens: int = 200


CREDENTIALS: tuple[CredentialSpec, ...] = (
    CredentialSpec(
        name="moonshot-kimi",
        provider="moonshot",
        env_var="MOONSHOT_API_KEY",
        description="Kimi / Moonshot credential for OpenCode agents",
    ),
    CredentialSpec(
        name="opencode-go",
        provider="openai",
        env_var="OPENCODE_API_KEY",
        description="OpenCode API credential shared by OpenCode Go and OpenCode Zen routes",
    ),
    CredentialSpec(
        name="anthropic-claude",
        provider="anthropic",
        env_var="ANTHROPIC_API_KEY",
        description="Anthropic Claude credential for OpenCode architect fallback",
    ),
)


MODELS: tuple[ModelSpec, ...] = (
    ModelSpec(
        alias="moonshotai-cn/kimi-k2.5",
        route_model="moonshot/kimi-k2.5",
        credential_name="moonshot-kimi",
        api_base="https://api.moonshot.cn/v1",
        description="Kimi K2.5 via Moonshot CN endpoint",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="opencode-go/minimax-m2.7",
        route_model="openai/minimax-m2.7",
        credential_name="opencode-go",
        api_base="https://opencode.ai/zen/go/v1",
        description="MiniMax M2.7 via OpenCode Go",
        smoke_max_tokens=300,
    ),
    ModelSpec(
        alias="opencode/deepseek-v4-flash-free",
        route_model="openai/deepseek-v4-flash-free",
        credential_name="opencode-go",
        api_base="https://opencode.ai/zen/v1",
        description="DeepSeek V4 Flash Free via OpenCode Zen",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="anthropic/claude-sonnet-4-6",
        route_model="anthropic/claude-sonnet-4-6",
        credential_name="anthropic-claude",
        description="Claude Sonnet 4.6 via Anthropic",
        smoke_max_tokens=64,
    ),
    ModelSpec(
        alias="agent-architect-primary",
        route_model="anthropic/claude-sonnet-4-6",
        credential_name="anthropic-claude",
        description="Agent Architect primary - Claude Sonnet 4.6",
        smoke_max_tokens=64,
    ),
    ModelSpec(
        alias="agent-architect-fallback",
        route_model="moonshot/kimi-k2.5",
        credential_name="moonshot-kimi",
        api_base="https://api.moonshot.cn/v1",
        description="Agent Architect fallback - Kimi K2.5",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="agent-developer-primary",
        route_model="openai/minimax-m2.7",
        credential_name="opencode-go",
        api_base="https://opencode.ai/zen/go/v1",
        description="Agent Developer primary - MiniMax M2.7",
        smoke_max_tokens=300,
    ),
    ModelSpec(
        alias="agent-developer-fallback",
        route_model="moonshot/kimi-k2.5",
        credential_name="moonshot-kimi",
        api_base="https://api.moonshot.cn/v1",
        description="Agent Developer fallback - Kimi K2.5",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="agent-qa-primary",
        route_model="openai/deepseek-v4-flash-free",
        credential_name="opencode-go",
        api_base="https://opencode.ai/zen/v1",
        description="Agent QA primary - DeepSeek V4 Flash Free",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="agent-qa-fallback",
        route_model="moonshot/kimi-k2.5",
        credential_name="moonshot-kimi",
        api_base="https://api.moonshot.cn/v1",
        description="Agent QA fallback - Kimi K2.5",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="agent-lightweight-primary",
        route_model="openai/deepseek-v4-flash-free",
        credential_name="opencode-go",
        api_base="https://opencode.ai/zen/v1",
        description="Agent light-weight primary - DeepSeek V4 Flash Free",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="agent-expert-primary",
        route_model="anthropic/claude-sonnet-4-6",
        credential_name="anthropic-claude",
        description="Agent Expert primary - Claude Sonnet 4.6",
        smoke_max_tokens=64,
    ),
    ModelSpec(
        alias="agent-expert-fallback",
        route_model="moonshot/kimi-k2.5",
        credential_name="moonshot-kimi",
        api_base="https://api.moonshot.cn/v1",
        description="Agent Expert fallback - Kimi K2.5",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="agent-releaser-primary",
        route_model="anthropic/claude-sonnet-4-6",
        credential_name="anthropic-claude",
        description="Agent Releaser primary - Claude Sonnet 4.6",
        smoke_max_tokens=64,
    ),
    ModelSpec(
        alias="agent-releaser-fallback",
        route_model="moonshot/kimi-k2.5",
        credential_name="moonshot-kimi",
        api_base="https://api.moonshot.cn/v1",
        description="Agent Releaser fallback - Kimi K2.5",
        smoke_max_tokens=200,
    ),
    ModelSpec(
        alias="agent-debugger-primary",
        route_model="openai/minimax-m2.7",
        credential_name="opencode-go",
        api_base="https://opencode.ai/zen/go/v1",
        description="Agent Debugger primary - MiniMax M2.7",
        smoke_max_tokens=300,
    ),
    ModelSpec(
        alias="agent-designer-primary",
        route_model="openai/deepseek-v4-flash-free",
        credential_name="opencode-go",
        api_base="https://opencode.ai/zen/v1",
        description="Agent Designer primary - DeepSeek V4 Flash Free",
        smoke_max_tokens=200,
    ),
)


def load_env_file(path: Path) -> None:
    if not path.exists():
        raise SystemExit(f"env file not found: {path}")
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


class LiteLLMAdminClient:
    def __init__(self, base_url: str, master_key: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.master_key = master_key

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None, timeout: int = 120) -> Any:
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(
            self.base_url + path,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.master_key}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                parsed = body
            raise RuntimeError(f"{method} {path} failed: HTTP {exc.code}: {parsed}") from exc

    def credentials_payload_text(self) -> str:
        return json.dumps(self.request("GET", "/credentials"), ensure_ascii=False)

    def model_info(self) -> list[dict[str, Any]]:
        return self.request("GET", "/model/info").get("data", [])


def model_db_id(existing_models: list[dict[str, Any]], alias: str) -> str | None:
    for item in existing_models:
        if item.get("model_name") == alias:
            info = item.get("model_info") or {}
            return info.get("id") or item.get("model_id")
    return None


def credential_payload(spec: CredentialSpec) -> dict[str, Any]:
    secret = os.environ.get(spec.env_var, "").strip()
    if not secret:
        raise ValueError(f"missing {spec.env_var}")
    return {
        "credential_name": spec.name,
        "credential_values": {"api_key": secret},
        "credential_info": {
            "custom_llm_provider": spec.provider,
            "description": spec.description,
        },
    }


def model_payload(spec: ModelSpec) -> dict[str, Any]:
    litellm_params: dict[str, Any] = {
        "model": spec.route_model,
        "litellm_credential_name": spec.credential_name,
    }
    if spec.api_base:
        litellm_params["api_base"] = spec.api_base
    return {
        "model_name": spec.alias,
        "litellm_params": litellm_params,
        "model_info": {"description": spec.description, "mode": "chat"},
    }


def selected(items: tuple[Any, ...], names: set[str] | None, attr: str) -> list[Any]:
    if not names:
        return list(items)
    return [item for item in items if getattr(item, attr) in names]


def upsert_credentials(client: LiteLLMAdminClient, specs: list[CredentialSpec], dry_run: bool) -> None:
    existing_text = "" if dry_run else client.credentials_payload_text()
    for spec in specs:
        payload = credential_payload(spec)
        exists = spec.name in existing_text
        if dry_run:
            print(f"credential {spec.name}: upsert using {spec.env_var}")
            continue
        print(f"credential {spec.name}: {'update' if exists else 'create'}")
        if exists:
            client.request("PATCH", f"/credentials/{spec.name}", payload)
        else:
            client.request("POST", "/credentials", payload)


def upsert_models(client: LiteLLMAdminClient, specs: list[ModelSpec], dry_run: bool) -> None:
    existing = [] if dry_run else client.model_info()
    for spec in specs:
        payload = model_payload(spec)
        db_id = model_db_id(existing, spec.alias)
        if dry_run:
            print(f"model {spec.alias}: upsert -> {spec.route_model}")
            continue
        print(f"model {spec.alias}: {'update' if db_id else 'create'} -> {spec.route_model}")
        if db_id:
            client.request("PATCH", f"/model/{db_id}/update", payload)
        else:
            client.request("POST", "/model/new", payload)


def smoke_test(client: LiteLLMAdminClient, specs: list[ModelSpec]) -> None:
    for spec in specs:
        payload = {
            "model": spec.alias,
            "messages": [{"role": "user", "content": "Say exactly: OK"}],
            "max_tokens": spec.smoke_max_tokens,
            "temperature": 0,
            "user": "registry_smoke_test",
        }
        start = time.time()
        response = client.request("POST", "/v1/chat/completions", payload, timeout=180)
        elapsed = time.time() - start
        choice = (response.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        content = message.get("content") or ""
        reasoning_chars = len(message.get("reasoning_content") or "")
        ok = content.strip() == "OK"
        print(
            f"smoke {spec.alias}: {'PASS' if ok else 'WARN'} "
            f"content={content!r} reasoning_chars={reasoning_chars} elapsed={elapsed:.2f}s"
        )
        if not ok:
            raise RuntimeError(f"smoke test for {spec.alias} did not return exact OK")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upsert LiteLLM credentials and DB-managed model aliases.")
    parser.add_argument("--base-url", default=os.environ.get("LITELLM_BASE_URL", DEFAULT_BASE_URL))
    parser.add_argument("--env-file", type=Path, help="Env file containing LITELLM_MASTER_KEY and provider API keys")
    parser.add_argument("--credentials-only", action="store_true")
    parser.add_argument("--models-only", action="store_true")
    parser.add_argument("--smoke", action="store_true", help="Run chat completion smoke tests after upsert")
    parser.add_argument("--dry-run", action="store_true", help="Validate inputs and print actions without calling write APIs")
    parser.add_argument(
        "--credential",
        action="append",
        choices=[spec.name for spec in CREDENTIALS],
        help="Limit to one credential; can be repeated",
    )
    parser.add_argument(
        "--model",
        action="append",
        choices=[spec.alias for spec in MODELS],
        help="Limit to one model alias; can be repeated",
    )
    parser.add_argument(
        "--create-opencode-key",
        action="store_true",
        help="Generate a LiteLLM virtual key scoped to agent aliases for OpenCode",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.credentials_only and args.models_only:
        raise SystemExit("--credentials-only and --models-only are mutually exclusive")
    if args.env_file:
        load_env_file(args.env_file)
    master_key = os.environ.get("LITELLM_MASTER_KEY", "").strip()
    if not master_key:
        raise SystemExit("missing LITELLM_MASTER_KEY")

    client = LiteLLMAdminClient(args.base_url, master_key)
    credential_names = set(args.credential or []) or None
    model_names = set(args.model or []) or None
    credential_specs = selected(CREDENTIALS, credential_names, "name")
    model_specs = selected(MODELS, model_names, "alias")

    try:
        if args.create_opencode_key:
            agent_aliases = [spec.alias for spec in MODELS if spec.alias.startswith("agent-")]
            if not agent_aliases:
                raise SystemExit("No agent aliases found in MODELS")
            payload = {
                "models": agent_aliases,
                "metadata": {"usage": "opencode"},
                "max_budget": 10.0,
                "rpm_limit": 100,
                "tpm_limit": 100000,
            }
            resp = client.request("POST", "/key/generate", payload)
            key = resp.get("key", "")
            alias = resp.get("key_alias", "N/A")
            print("=" * 60)
            print("LITELLM_API_KEY generated successfully")
            print("=" * 60)
            print()
            print(f"  LITELLM_API_KEY={key}")
            print(f"  Key alias:     {alias}")
            print(f"  RPM limit:    100")
            print(f"  Budget:       $10.00")
            print(f"  Scoped models: {', '.join(agent_aliases)}")
            print()
            print("Add this to your agent-config/.env file:")
            print(f"  LITELLM_API_KEY={key}")
            print(f"  LITELLM_BASE_URL=http://localhost:4000/v1")
            print()
            print("⚠️  This key is shown only once. Save it now.")
            return 0
        if not args.models_only:
            upsert_credentials(client, credential_specs, args.dry_run)
        if not args.credentials_only:
            upsert_models(client, model_specs, args.dry_run)
        if args.smoke and not args.credentials_only and not args.dry_run:
            smoke_test(client, model_specs)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    return 0


if __name__ == "__main__":
    sys.exit(main())
