---
title: Roadmap
description: Current project status, what's been built, and prioritized next steps.
---

Skein's compilation pipeline, runtime, standard library, editor tooling, and distribution packaging are all functional. This page covers the current state, forward-looking priorities, and a history of completed work.

## Current State

The end-to-end pipeline works: `.skein` source files lex, parse, analyze, generate Core Erlang, compile to BEAM bytecode, and execute on OTP. The runtime supports agents, HTTP handlers, queue/schedule/topic handlers, storage (ETS and Ecto/SQLite), LLM integration with streaming, tool calling, memory, tracing, and event sourcing.

**Test suite:** 1,343 tests, 182 property tests, 0 failures

**13 example programs** compile and run, covering HTTP APIs, agents with LLM and tools, queue workers, pub/sub notifications, background tasks, audit logging, semantic search, and a conversational assistant.

---

## What's Next

The biggest gaps are in the **type system** (most expressions infer to `:unknown`), **spec-example alignment** (canonical examples use unimplemented syntax), and **runtime capability enforcement** (4 of 9 subsystems don't check capabilities at runtime). These are the priorities.

### Tier 1: Critical

These items undermine core language promises.

#### 1. Real Type Inference

`infer_type(%AST.FieldAccess{})` returns `{:unknown, []}`. Pattern variables bind as `:unknown`. This means `user.email + 42` compiles without error — the "Types Are Contracts" promise is not delivered.

**Target:** Field access resolves types through user-defined type declarations. Pattern bindings in `match` carry the inner types of `Result`, `Option`, and enum variants. Type mismatches on field access produce `E0020`.

#### 2. Schema Derivation for Nested Types

`type Order { customer: Customer }` generates `{"type": "object"}` for the `customer` field instead of inlining `Customer`'s schema. Enum variants lose field information. `Map[K, V]` loses type parameters.

**Target:** Nested user types generate fully resolved JSON Schema. Enum variants produce `oneOf`. `Map[String, Int]` generates `additionalProperties`.

#### 3. Spec-Example Alignment

The canonical examples in `SKEIN_SPEC.md` sections 8.2–8.5 use syntax that doesn't exist: object literals, named arguments, tuple destructuring, unit type `()`, and `agent.run_sync()`. An LLM given the spec will generate code that doesn't compile.

**Target:** Either implement the missing syntax (map literals and named arguments are fundamental) or rewrite spec examples to use only implemented syntax.

#### 4. Runtime Capability Enforcement

Compile-time capability enforcement is complete for both modules and agents (E0012, E0014, E0015, W0002). However, 4 of 9 runtime effect subsystems still ignore capabilities at execution time.

| Subsystem | Compile-time | Runtime |
|-----------|-------------|---------|
| HTTP out | ✅ | ✅ |
| Store | ✅ | ✅ |
| Memory | ✅ | ✅ |
| Event emit | ✅ | ✅ |
| Tool | ✅ | Presence-only (doesn't check specific tool name) |
| LLM | ✅ | Presence-only (doesn't check provider/model) |
| Topic | ✅ | ❌ Ignored |
| Process | ✅ | ❌ Ignored |
| Timer | ✅ | ❌ Ignored |

### Tier 2: Serious

Significant functionality gaps that affect production readiness.

#### 5. Agent Instance-Scoped Memory

Memory uses the declared namespace without instance scoping. Two concurrent agent instances sharing a `memory.kv` namespace overwrite each other. Memory keys should be automatically scoped as `{agent_name}:{instance_id}:{key}`.

#### 6. Production LLM Backend

The LLM client has 7 test backends but zero HTTP backends. No real LLM provider can be called. Needs an HTTP-based backend (Anthropic, OpenAI, or generic) with API key management and rate limit handling.

#### 7. Error Context and Fix Code

The `context` field on `Skein.Error` is always `nil`. `fix_code` is present on only 5 of 24 error codes. This weakens the LLM self-correction loop that is central to Skein's design.

#### 8. Tool Input Validation

Tool inputs go directly to the implementation function without schema validation. The `validation_error` variant exists in `Tool.Error` but is never constructed. An LLM calling a tool with malformed input gets a runtime crash instead of a structured error.

#### 9. Queue Naming Convention

The spec uses `queue.consume` but the implementation uses `queue.in`. These should be aligned.

#### 10. Agent Events to EventStore

Events emitted via `emit` inside agents are stored in `gen_statem` data but not appended to the EventStore. If the agent crashes, emitted events are lost.

#### 11. Schedule Auto-Firing

Schedule handlers register their cron expression but never fire automatically. Only manual `trigger/1` works.

#### 12. Agent Nesting Inside Modules

The spec shows agents nested inside modules (`module RefundService { agent RefundAgent { ... } }`), but the parser's `parse_declaration` doesn't include `agent` as a valid module-level construct.

### Post-MVP Backlog

Items that are planned but not yet prioritized:

- Erlang/Elixir FFI (`extern`)
- Hot code upgrades
- Web IDE (trace viewer)
- `llm.rerank` for RAG pipelines
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
| 5 | Storage | ETS-backed `store.table` with get, put, delete, query |
| 6 | Agents | Agent state machines, phases, transitions, memory, LLM, tools, events |
| 7 | Testing & CLI | Test constructs, full CLI (new, build, test, run, trace) |

### Infrastructure (Phase 8)

| Sub-phase | Name | Summary |
|-----------|------|---------|
| 8a | Test Infrastructure | Scenario tests (`given`/`expect`), golden trace tests, replay engine with recorded response injection |
| 8b | Storage Backend | Ecto schema generation, migrations, SQLite via `ecto_sqlite3`, persistent EventStore |
| 8c | HTTP Server | Bandit + Plug integration, `req.json[T]` body validation |
| 8d | Canonical Examples | 13 working `.skein` programs with integration tests |
| 8e | Queue & Schedule | `handler queue` and `handler schedule` constructs |
| 8f | LLM Streaming | `llm.stream` with chunked responses and trace spans |

### Hardening (Tier 2 — Completed)

| Item | Summary |
|------|---------|
| Float division codegen | `/` uses Erlang `/` for floats, `div` for integers |
| Contextual keywords | `input`, `output`, `from`, `trace`, etc. no longer globally reserved |
| Multiple `emit` per handler | All events accumulated, not just the last |
| Replay with response injection | Recorded LLM/tool responses can be replayed into live execution |
| Persistent EventStore | SQLite-backed event store (opt-in, ETS default) |
| PropCheck agent stateful test | Stateful property test for agent lifecycle — passing |
| Agent capability enforcement | E0012, E0014, W0002 now enforced for agents (not just modules) |

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
| Topic pub/sub | `handler topic` + `topic.publish` effect |
| Idempotency | `idempotent(key)` with TTL-based deduplication |
| Process spawning | `process.spawn` with DynamicSupervisor |
| Timers | `timer.after`, `timer.interval`, `timer.cancel` |
| Event sourcing | Unified `EventStore` with query, memory rebuild from events |
| `suspend`/`resume` | Agent lifecycle management |
| `respond.text`/`respond.html` | Content-type response variants |
| `trace.annotate` | Custom annotations in the event stream |
| `llm.embed` | Embedding vector generation |

### Error System

20 error codes + 3 warning codes, all aligned with the language specification. Every error includes `code`, `severity`, `message`, `location`, and `fix_hint`.

### Editor Tooling

- **VS Code extension** with TextMate grammar, 30+ snippets, LSP client
- **Language Server** (GenLSP): diagnostics, document symbols, hover, go-to-definition, completions, semantic tokens

### Distribution

- **Burrito binaries** for Linux x86_64, macOS x86_64, macOS ARM64
- `skein build --output` writes `.beam` files to disk
- See [Distribution](/Skein/roadmap/distribution/) for remaining packaging work
