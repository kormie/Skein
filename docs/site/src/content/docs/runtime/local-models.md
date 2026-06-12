---
title: Local Models for Development
description: Serve llm.chat/llm.json from a local model server (oMLX, Ollama, LM Studio, vLLM) in dev — zero source edits, capabilities untouched.
---

Testing agents against Anthropic means real inference spend. A local
model server can serve dev traffic for free — and in Skein, switching
backends never touches source: `capability model("anthropic",
"claude-opus-4-8")` stays the code's contract whether traffic goes to
Anthropic or `localhost`.

## Environment profiles in skein.toml

The `[llm]` section selects the production backend; `[env.<name>.llm]`
sections override it per environment:

```toml
[llm]                      # default: production
backend = "anthropic"

[env.dev.llm]
backend = "openai_compatible"
base_url = "http://localhost:10240/v1"
api_key_env = "OMLX_API_KEY"        # optional; most local servers need none
model_map = { "claude-opus-4-8" = "mlx-community/Qwen3-30B" }
```

`model_map` remaps the model named in the capability declaration to
whatever the local server hosts. Unmapped models pass through unchanged.

## Selecting an environment

`skein run` and `skein test` resolve the active environment from the
`--env` flag, then the `SKEIN_ENV` environment variable:

```bash
# Dev traffic served by the local server — zero source edits
SKEIN_ENV=dev skein test
skein test --env dev

# Production: Anthropic, exactly as declared
skein run
```

## The OpenAI-compatible backend

`backend = "openai_compatible"` speaks `POST {base_url}/chat/completions`
— the de facto local standard served by oMLX, Ollama, LM Studio,
llama.cpp, and vLLM. Details:

- `llm.json` injects the schema into the system prompt (the one approach
  every local server supports) and strips markdown fences from the reply
- `llm.embed` calls `POST {base_url}/embeddings`
- `llm.stream` performs a regular completion returned as a single chunk
  (SSE framing varies too much across local servers)
- A server that is down produces a structured `LlmError` naming the
  `base_url` — never a crash

Capability checks and tracing are unchanged: every call is still checked
against the declared `model(...)` capability, and each llm trace span
records which `backend` and `base_url` served it, so a trace never
leaves you guessing whether you burned tokens.

## Embeddings

Anthropic has no embeddings API, so `llm.embed` always runs through an
OpenAI-compatible `/embeddings` endpoint. Two setups cover development
and production:

```toml
# Development: a local embedding model (Ollama, LM Studio, vLLM, ...)
[env.dev.llm]
backend = "openai_compatible"
base_url = "http://localhost:11434/v1"
model_map = { "voyage-3-large" = "nomic-embed-text" }

# Production: Voyage AI (Anthropic's recommended embeddings provider) —
# its /embeddings endpoint speaks the same OpenAI-compatible shape.
[env.prod.llm]
backend = "openai_compatible"
base_url = "https://api.voyageai.com/v1"
api_key_env = "VOYAGE_API_KEY"
```

The source and capability declarations never change: declare
`capability model("voyage", "voyage-3-large")`, call
`llm.embed("voyage-3-large", text)`, and `model_map` resolves the model
per environment. `examples/semantic_search.skein` is the runnable
end-to-end example. Embed spans record `backend`/`base_url` like chat
spans, and a server that is down is a structured `LlmError`.

## Backends

| `backend` | Serves calls via |
|-----------|------------------|
| `anthropic` | Anthropic Messages API (production default) |
| `bedrock` | Amazon Bedrock Converse API — SigV4-signed with credentials from the AWS env vars or the AWS credential chain (`AWS_PROFILE` files, EKS IRSA, ECS task roles, EC2 instance metadata; cached and auto-refreshed); set `region` (or `AWS_REGION`) and `model_map` to remap declared models to Bedrock model IDs (e.g. `"global.anthropic.claude-sonnet-4-6"`) |
| `openai_compatible` | `POST {base_url}/chat/completions` on a local/self-hosted server |
| `test` | Deterministic in-process responses (CI without inference) |

## Example: oMLX on Apple Silicon

```toml
[env.dev.llm]
backend = "openai_compatible"
base_url = "http://localhost:10240/v1"
model_map = { "claude-opus-4-8" = "mlx-community/Qwen3-30B" }
```

```bash
SKEIN_ENV=dev skein test     # local, free
skein run                    # Anthropic, as declared
```
