# Fix: ChatGPT Responses API Non-Streaming Bridge

## Issue

Non-streaming `/v1/chat/completions` calls to `chatgpt/gpt-5.6-sol` and `chatgpt/gpt-5.6-luna` fail with:

```
ChatgptException - Unknown items in responses API response: []
```

GitHub Issue: #28

## Root Cause

LiteLLM v1.92.0 uses the Responses API bridge (`LiteLLMResponsesTransformationHandler`) when routing chat completions requests to models with `mode: responses` and `litellm_provider: chatgpt`. 

The bridge:
1. `transform_request()` — Converts chat completions messages → Responses API `input` format
2. Sends via `ChatGPTResponsesAPIConfig` → ChatGPT Responses API endpoint
3. `transform_response_api_response()` — Parses SSE response into `ResponsesAPIResponse`
4. `transform_response()` — Converts `ResponsesAPIResponse` → chat completions format

Step 3 produces a `ResponsesAPIResponse` with empty `output` when the HTTP client does NOT stream. The SSE events are correctly received but the output extraction from the `response.completed` event fails because the event payload contains `"output":[]`.

## Verified Working Paths

| Path | Streaming | Non-Streaming |
|---|---|---|
| `/v1/responses` → `gpt-5.6-sol` | ✅ Works | ✅ Works |
| `/v1/chat/completions` → `gpt-5.6-sol` | ✅ Works | ❌ Fails: empty output |
| `/v1/chat/completions` → `agent-architect-primary` (old) | ✅ Works (falls back) | ✅ Works |

## Practical Impact

OpenCode agents always send `"stream": true` for chat completions. Since the streaming path works correctly, **agent alias routing updates are not blocked by this issue**. The bug only affects non-streaming chat completions calls, which OpenCode does not make.

## Remediation (Recommended)

### Option A: LiteLLM Version Upgrade (preferred)
Upgrade LiteLLM to a version that fixes the non-streaming responses→chat bridge. Check https://github.com/BerriAI/litellm/releases for fix.

### Option B: Custom LiteLLM Patch
In `transformation.py` `_build_completed_response_from_chunk`, ensure output items extracted from SSE event stream are properly included in the `ResponsesAPIResponse` even when the `response.completed` event has empty output.

### Option C: Register models with mode=chat
If the models are registered as `mode: chat` with a compatible API base, the responses bridge is not used. However, this would lose the Responses-API-specific features.

## Current Model Config (via Admin UI/DB)

```
gpt-5.6-sol → chatgpt/gpt-5.6-sol (mode: responses)
gpt-5.6-luna → chatgpt/gpt-5.6-luna (mode: responses)
```
