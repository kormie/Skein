---
title: Roadmap
description: Current project status, what's been built, and prioritized next steps.
---

Skein's compilation pipeline, runtime, standard library, editor tooling, and distribution packaging are all functional. This page covers the current state, forward-looking priorities, and a history of completed work. The canonical, more detailed version lives in [`docs/ROADMAP.md`](https://github.com/kormie/Skein/blob/main/docs/ROADMAP.md).

## Current State

The end-to-end pipeline works: `.skein` source files lex, parse, analyze, generate Core Erlang, compile to BEAM bytecode, and execute on OTP. The runtime supports agents, HTTP handlers, queue/schedule/topic handlers, storage (ETS and Ecto/SQLite), LLM integration with a production Anthropic backend and streaming, tool calling, memory, tracing, and event sourcing.

**Test suite:** 1,413 tests, 189 property tests, 0 failures

**14 example programs** (thirteen single-file plus one multi-file project) compile and run, covering HTTP APIs, agents with LLM and tools, queue workers, pub/sub notifications, background tasks, audit logging, semantic search, and a conversational assistant. All are covered by integration tests.

---

## What's Next

### Tier 1: Language Surface

#### 1. Named Arguments in Calls

The spec grammar allows named arguments (`llm.chat(model: "...", system: "...")`), but the parser only supports positional arguments. All shipped examples use the positional form.

**Target:** Named args parse, analyze (unknown/duplicate names are structured errors), and reorder to positional at codegen.

#### 2. Agent Nesting Inside Modules

The spec shows agents nested inside modules (`module RefundService { agent RefundAgent { ... } }`), but the parser doesn't accept `agent` as a module-level declaration. The `market_research` example works around this with one file per construct.

#### 3. Types Usable from Agents

Agents can't declare `type` blocks, so `llm.json[SomeType]` — the schema-constrained LLM decision pattern — only works in module functions today. Lands naturally once agents can nest inside modules.

### Tier 2: Runtime Completeness

#### 4. Schedule Auto-Firing

Schedule handlers register their cron expression but only fire via manual `trigger/1`. A running service should fire them on schedule.

#### 5. Agent Events to EventStore

Events emitted via `emit` inside agents live in `gen_statem` data but aren't appended to the EventStore, so they're lost on crash and invisible to `EventStore.query/1`.

#### 6. Replay Backend Injection

The replay engine can load traces and rebuild memory, but the LLM/HTTP/tool runtimes don't consult replay state — recorded-mode replay can't yet intercept live effects.

#### 7. Stream/Pool-Scoped Runtime Capability Checks

`process.spawn`, `timer`, and `event.log` check capability *presence* at runtime but not parameters. Full enforcement needs a surface decision first: the declared capability names a pool/stream label, while the runtime call carries a different value (the task/event name).

#### 8. `process.spawn` Task Bodies

`process.spawn("name")` spawns a supervised, traced no-op task. Attaching real work to the spawned process needs a call-surface decision (likely a function reference argument).

### Tier 3: Polish

- **Enum value-level exhaustiveness warning** — variant coverage is checked, but literal field patterns without a wildcard can still `case_clause` at runtime; the analyzer should warn.
- **Spec section 8 sweep** — after named args and agent nesting land, every spec example should compile (and be covered by `spec_examples_test.exs`) or carry an explicit "Planned" annotation.

### Post-MVP Backlog

- Erlang/Elixir FFI (`extern`)
- Hot code upgrades
- Web IDE (trace viewer)
- `llm.rerank` for RAG pipelines, and an embeddings-capable backend for `llm.embed`
- Human-in-the-loop approval workflows
- Guard expressions in match arms
- Managed deployment platform
- Marketplace for tools/connectors

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
| Persistent EventStore | SQLite-backed event store (opt-in, ETS default) |
| Error system | 21 error + 3 warning codes; `context` and `fix_code` populated on all analyzer/parser/lexer errors |

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
- `skein build --output` writes `.beam` files to disk
- See [Distribution](/Skein/roadmap/distribution/) for remaining packaging work
