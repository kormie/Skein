---
title: Roadmap
description: Current project status, what's been built, and prioritized next steps.
---

Skein's compilation pipeline, runtime, standard library, editor tooling, and distribution packaging are all functional. This page covers the current state, forward-looking priorities, and a history of completed work. The canonical, more detailed version lives in [`docs/ROADMAP.md`](https://github.com/kormie/Skein/blob/main/docs/ROADMAP.md).

## Current State

The end-to-end pipeline works: `.skein` source files lex, parse, analyze, generate Core Erlang, compile to BEAM bytecode, and execute on OTP. The runtime supports agents, HTTP handlers, queue/schedule/topic handlers, storage (ETS and Ecto/SQLite), LLM integration (production Anthropic backend with streaming, AWS Bedrock, and an OpenAI-compatible backend for local models), tool calling, memory, tracing, replayable event sourcing, and guard expressions in match arms.

The full test suite (unit, property-based, and integration) runs green in CI on every change — see the CI badge on the README for current totals; counts aren't tracked here because they grow with every change.

**Sixteen example programs** (thirteen single-file plus the multi-file `market_research` project and its single-file variant) compile and run warning-free, covering HTTP APIs, agents with LLM and tools, queue workers, pub/sub notifications, background tasks, audit logging, semantic search, and a conversational assistant. All are covered by integration tests.

## Release Status

The release train so far: **v0.2.0** and **v0.3.0** shipped 2026-06-11, and **v1.0.0-rc.1** is tagged — the spec is frozen for 1.0. The rc soaks while the remaining **v1.0.0 Release** milestone items (documentation accuracy and example polish found by the release-readiness audits) land; then the rc promotes to **v1.0.0**.

---

## What's Next

### v1.0.0 GA

The [v1.0.0 Release milestone](https://github.com/kormie/Skein/milestone/6) gates the GA tag. Everything in it is audit-driven cleanup: compiler fixes for the W0001 interpolation false positive (#196) and the float-literal lexer crash (#197), warning-free examples (#199), and meta-doc/docs-page accuracy (#200, #223–#229).

### Post-1.0 Backlog

Tracked in [`docs/ROADMAP.md`](https://github.com/kormie/Skein/blob/main/docs/ROADMAP.md) with linked issues:

- **v1.1: Hardening & Language** — `llm.rerank` (#145), LSP code actions phase 2 (#150), docs/spec drift guards in CI (#202), Bedrock follow-ups (credential chain #179, real token streaming #178, ARN model IDs #180)
- **v1.2: Interop & Agent Workflows** — Erlang/Elixir FFI (`extern`, #141), human-in-the-loop approval workflows (#144), web trace viewer (#143), CLI TUI (#171)
- **Future: Platform** — hot code upgrades (#142), managed deployment platform (#148), tool/connector marketplace (#149)

---

## Completed Work

Everything below is implemented and tested.

### Core Pipeline (Phases 1–7)

| Phase | Name | Summary |
|-------|------|---------|
| 1 | Hello BEAM | End-to-end compilation: lexer → parser → analyzer → Core Erlang → BEAM |
| 2 | Type System | Type checking, schemas, constraint annotations, `Option[T]`, `Result[T, E]`, `!`/`?` operators |
| 3 | Capabilities & Effects | Capability declarations, compile-time checking (modules + agents), HTTP client, tracing |
| 4 | Handlers & HTTP | HTTP handlers with routing, request dispatch, Bandit + Plug server |
| 5 | Storage | ETS-backed `store.table` with get, get!, put, put!, delete, query |
| 6 | Agents | Agent state machines, phases, transitions, memory, LLM, tools, events |
| 7 | Testing & CLI | Test constructs, full CLI (new, build, test, run, trace) |

### Infrastructure (Phase 8)

| Sub-phase | Name | Summary |
|-----------|------|---------|
| 8a | Test Infrastructure | Scenario tests (`given`/`expect`), golden trace tests, replay engine (trace loading + memory rebuild) |
| 8b | Storage Backend | Ecto schema generation, migrations, SQLite via `ecto_sqlite3`, persistent EventStore |
| 8c | HTTP Server | Bandit + Plug integration, `req.json[T]` body validation |
| 8d | Canonical Examples | 14 working programs with integration tests |
| 8e | Queue & Schedule | `handler queue` and `handler schedule` constructs |
| 8f | LLM Streaming | `llm.stream` with chunked responses and trace spans |

### Type System & Schemas

- Field access resolves through user-defined type declarations; `user.email + 42` is a type error (E0020)
- Pattern bindings carry the inner types of `Result`, `Option`, and enum variants
- Nested user types generate fully resolved JSON Schema; enum variants produce `oneOf`; `Map[K, V]` generates `additionalProperties`; circular references are safe

### LLM Integration

- Production **Anthropic backend** (Messages API): `chat`, `json` (schema-in-system-prompt), `stream` (SSE), retry on 429, structured errors, API-key redaction
- Model-scoped runtime capability checks: `llm.chat("model-x", ...)` without a matching `capability model(...)` is blocked
- Current model IDs throughout examples and docs

### Hardening

| Item | Summary |
|------|---------|
| Float division codegen | `/` uses Erlang `/` for floats, `div` for integers |
| String-literal match patterns | `match s { "approve" -> ... }` compiles to proper binary patterns |
| `state.field` everywhere | Agent state access works in nested expression positions |
| `method!(args)` parsing | `store.users.get!(id)` parses as unwrap-of-call (likewise `?`) |
| Contextual keywords | `input`, `output`, `state`, etc. no longer globally reserved |
| Multiple `emit` per handler | All events accumulated, not just the last |
| Agent instance-scoped memory | Keys scoped as `{agent}:{instance}:{key}`; concurrent instances don't collide |
| Tool input validation | Inputs validated against the tool's JSON Schema; `validation_error` on mismatch |
| Capability naming | `queue.consume` / `schedule.trigger` (old names get a targeted rename hint) |
| Cross-module `tool.call` | `implement` blocks compile to callable entry points; tools registered at module load (v0.1.5) |
| Variant construction | `Ok(x)`, `Err(e)`, `Event.Charge(n)`, `ErrName.from(cause)`, and zero-field forms (`Status.Active`, bare `Active`) all compile in expression position; unknown variants and wrong arity are structured errors |
| Spec section 8 sweep | Every section-8 example compiles with zero diagnostics (pinned by `spec_examples_test.exs`) |
| zsh tab-completion | `skein completions zsh` (drift-tested against the help text) |
| MCP compile_check fidelity | Warnings included (`Compiler.check_file/1`); project mode checks `src/` + `test/` like `skein test` |
| Structured assertion failures | Failing asserts report operands, rendered expression, and `file:line` (Skein.Runtime.AssertionError) |
| `skein new` git init | Repo + baseline `.gitignore` scaffolded by default (`--no-git` to skip; never nests inside an existing work tree) |
| Agent events to EventStore | `emit` flushes durably as `:user_event` (agent/instance/phase tags); crash-safe |
| Schedule auto-firing | Cron tick with per-minute dedup; Server registers schedule handlers; `tick_at/1` for deterministic tests |
| Capability checks in test blocks | Effects inside `test`/`scenario`/`golden` require capabilities (E0012) and count as usage (no scaffold W0002) |
| Named arguments in calls | `f(name: value)` for local fns and documented effect signatures; analyzer rewrites to positional order at compile time (E0026 on misuse) |
| Agent nesting inside modules | `module Foo { agent Bar }` → `Skein.Agent.Foo.Bar`; module types and capabilities apply to the nested agent |
| Types usable from agents | Module types visible to nested agents; derived JSON Schema flows into `llm.json[T]` from agent handlers |
| Persistent EventStore | SQLite-backed event store (opt-in, ETS default) |
| Error system | Structured error/warning codes (spec §7); `context` and `fix_code` populated on all analyzer/parser/lexer errors |
| Replay backend injection | Recorded traces intercept `llm`/`http`/`tool` effects on replay; exhausted or mismatched traces are structured errors, never silent live calls (#73) |
| Scoped capability labels | `memory.kv`/`event.log`/`process.spawn`/`timer` capability params are scope labels the compiler threads into runtime calls and the runtime enforces exactly (#69, #57) |
| Task bodies | `process.spawn("name", &fn)` and `timer.after`/`timer.interval` work arguments run in supervised tasks (#74, #155) |
| Local LLM backends | OpenAI-compatible backend + `[env.<name>.llm]` profiles in `skein.toml` with `model_map` for Ollama/LM Studio/vLLM dev loops (#107) |
| AWS Bedrock backend | Converse API with SigV4 signing, `region` + `model_map` config (#173) |
| Match guards | `pattern if expr ->` with a guard-safe operator subset (#147) |
| Value-level exhaustiveness | W0004 warns when a variant is covered only by literal field patterns (#76) |
| LSP code actions | Editor quickfixes built from each diagnostic's `fix_hint`/`fix_code` (#108) |
| `llm.embed` backend | Embeddings served by the OpenAI-compatible backend's `/embeddings` endpoint (#146) |

### Standard Library

11 modules with 101 functions:

| Module | Purpose |
|--------|---------|
| `String` | Manipulation, search, splitting, formatting |
| `Int` / `Float` | Arithmetic, parsing, conversion |
| `List` | Functional operations (map, filter, reduce, etc.) |
| `Map` | Key-value operations |
| `Set` | Mathematical set operations |
| `Option` | `Some(T)` / `None` handling |
| `Result` | `Ok(T)` / `Err(E)` handling |
| `Uuid` | UUID v4 generation |
| `Instant` | ISO 8601 timestamps |
| `Duration` | Time intervals |

### Additional Capabilities

| Feature | Description |
|---------|-------------|
| Topic pub/sub | `handler topic` + `topic.publish` effect (name-scoped runtime checks) |
| Idempotency | `idempotent(key)` with TTL-based deduplication |
| Process spawning | `process.spawn` with DynamicSupervisor |
| Timers | `timer.after`, `timer.interval`, `timer.cancel` |
| Event sourcing | Unified `EventStore` with query, memory rebuild from events |
| `suspend`/`resume` | Agent lifecycle management |
| `respond.text`/`respond.html` | Content-type response variants |
| `trace.annotate` | Custom annotations in the event stream |
| `llm.embed` | Embedding vectors (requires an embeddings-capable backend) |

### Editor Tooling

- **VS Code extension** with TextMate grammar, 30+ snippets, LSP client
- **Language Server** (GenLSP): diagnostics, document symbols, hover, go-to-definition, completions, semantic tokens — with request/response integration tests

### Distribution

- **Burrito binaries** for Linux x86_64/ARM64 and macOS x86_64/ARM64
- **GitHub Release automation** — binaries published automatically on `v*` tags
- **Auto-tagged releases** — a green version-bump merge to `main` tags, builds, and publishes the release with no manual steps; each release carries a docs snapshot (incl. `llms*.txt`)
- `skein build --output` writes `.beam` files to disk
- See [Distribution](/Skein/roadmap/distribution/) for remaining packaging work
