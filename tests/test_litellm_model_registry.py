import unittest

from scripts import litellm_model_registry as registry


class ModelRegistryTest(unittest.TestCase):
    def _spec(self, alias: str):
        specs = [spec for spec in registry.MODELS if spec.alias == alias]
        self.assertEqual(len(specs), 1, f"expected one spec for {alias}")
        return specs[0]

    def test_build_aliases_are_singletons_and_use_expected_providers(self) -> None:
        primary = registry.model_payload(self._spec("agent-build-primary"))
        self.assertEqual(
            primary,
            {
                "model_name": "agent-build-primary",
                "litellm_params": {
                    "model": "chatgpt/gpt-5.6-sol",
                    "reasoning_effort": "high",
                },
                "model_info": {
                    "description": "Agent Build primary - GPT-5.6 Sol via ChatGPT OAuth",
                    "mode": "chat",
                },
            },
        )

        fallback = registry.model_payload(self._spec("agent-build-fallback"))
        self.assertEqual(
            fallback,
            {
                "model_name": "agent-build-fallback",
                "litellm_params": {
                    "model": "deepseek-v4-flash",
                    "litellm_credential_name": "deepseek-api",
                    "api_base": "",
                    "custom_llm_provider": "deepseek",
                    "reasoning_effort": "",
                },
                "model_info": {
                    "description": "Agent Build fallback - DeepSeek V4 Flash",
                    "mode": "chat",
                },
            },
        )
        self.assertNotIn("litellm_credential_name", primary["litellm_params"])
        self.assertNotIn("api_base", primary["litellm_params"])

    def test_agent_developer_routes(self) -> None:
        primary_specs = [
            spec for spec in registry.MODELS if spec.alias == "agent-developer-primary"
        ]
        self.assertEqual(len(primary_specs), 1)

        primary = registry.model_payload(primary_specs[0])
        self.assertEqual(
            primary,
            {
                "model_name": "agent-developer-primary",
                "litellm_params": {
                    "model": "openai/kimi-k2.7-code",
                    "litellm_credential_name": "opencode-go",
                    "api_base": "https://opencode.ai/zen/go/v1",
                },
                "model_info": {
                    "description": "Agent Developer primary - Kimi K2.7 Code",
                    "mode": "chat",
                },
            },
        )
        self.assertNotIn("chatgpt/gpt-5.6-sol", repr(primary))
        self.assertNotIn("openai/minimax-m2.7", repr(primary))

        fallback_specs = [
            spec for spec in registry.MODELS if spec.alias == "agent-developer-fallback"
        ]
        self.assertEqual(len(fallback_specs), 1)
        fallback = registry.model_payload(fallback_specs[0])
        self.assertEqual(
            fallback["litellm_params"],
            {
                "model": "openai/deepseek-v4-flash-free",
                "litellm_credential_name": "opencode-go",
                "api_base": "https://opencode.ai/zen/v1",
            },
        )
        self.assertEqual(fallback["model_info"]["mode"], "chat")


if __name__ == "__main__":
    unittest.main()
