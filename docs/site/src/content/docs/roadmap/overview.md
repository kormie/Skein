---
title: Roadmap
description: Current project status, what's been built, and prioritized next steps.
---

Skein's compilation pipeline, runtime, standard library, editor tooling, and distribution packaging are all functional. This page covers the current state, forward-looking priorities, and a history of completed work.

## Current State

The end-to-end pipeline works: `.skein` source files lex, parse, analyze, generate Core Erlang, compile to BEAM bytecode, and execute on OTP. The runtime supports agents, HTTP handlers, queue/schedule/topic handlers, storage (ETS and Ecto/SQLite), LLM integration with streaming, tool calling, memory, tracing, and event sourcing.

**Test suite:** 1,176+ tests, 182+ property tests, 0 failures

**11 example programs** compile and run, covering HTTP APIs, agents with LLM and tools, queue workers, pub/sub notifications, background tasks, and audit logging.

---

## What's Next

The biggest gaps are in the **type system** (most expressions infer to `:unknown`), **spec-example alignment** (canonical examples use unimplemented syntax), and **runtime capability enforcement** (4 of 9 subsystems don't check capabilities). These are the priorities.

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

4 of 9 runtime effect subsystems ignore capabilities entirely. Tool and LLM checks are presence-only.

| Subsystem | Current | Target |
|-----------|---------|--------|
| Tool | Any `tool.use` passes | Check specific tool name |
| LLM | Any `model` passes | Check provider and model |
| Topic | Capabilities ignored | Check topic name |
| Process | Capabilities ignored | Check agent name and max |
| Timer | Capabilities ignored | Check `timer` capability |
| EventStore | Capabilities ignored | Check stream name |

### Tier 2: Serious

Significant functionality gaps that affect production readiness.

#### 5. Agent Stateful Property Test

The PropCheck stateful test for agent lifecycle doesn't compile because it calls `Skein.Compiler.compile_string/1` from `skein_runtime`, which doesn't depend on `skein_compiler`. Needs a cross-app test dependency or relocation.

#### 6. Agent Instance-Scoped Memory

Memory uses the declared namespace without instance scoping. Two concurrent agent instances sharing a `memory.kv` namespace overwrite each other. Memory keys should be automatically scoped as `{agent_name}:{instance_id}:{key}`.

#### 7. Replay Engine — Actual Replay

`Skein.Runtime.Replay` reads traces and reconstructs memory but cannot inject recorded responses into a live execution. The three replay modes (recorded/live/hybrid) described in the design are not functional.

#### 8. Production LLM Backend

The LLM client has 7 test backends but zero HTTP backends. No real LLM provider can be called. Needs an HTTP-based backend (Anthropic, OpenAI, or generic) with API key management and rate limit handling.

#### 9. Error Context and Fix Code

The `context` field on `Skein.Error` is always `nil`. `fix_code` is present on only 5 of 24 error codes. This weakens the LLM self-correction loop that is central to Skein's design.

#### 10. Division Codegen

Codegen uses Erlang `:div` for all `/` operations, which crashes on float operands. Should use `/` for float division and `div` for integer division.

#### 11. Multiple `emit` in a Single Handler

Multiple `emit` calls in a handler sequence may lose events. The handler return tuple carries only the last event set rather than accumulating.

#### 12. Tool Input Validation

Tool inputs go directly to the implementation function without schema validation. The `validation_error` variant exists in `Tool.Error` but is never constructed. An LLM calling a tool with malformed input gets a runtime crash instead of a structured error.

### Tier 3: Moderate

Spec/implementation drift and polish items.

#### 13. Contextual Keywords

`input`, `output`, `errors`, `state`, `strategy`, and other tokens are reserved globally but only meaningful in specific contexts. You can't name a variable `input` anywhere.

#### 14. Queue Naming Convention

The spec uses `queue.consume` but the implementation uses `queue.in`. These should be aligned.

#### 15. Agent Events to EventStore

Events emitted via `emit` inside agents are stored in `gen_statem` data but not appended to the EventStore. If the agent crashes, emitted events are lost.

#### 16. Persistent EventStore Backend

The EventStore is ETS-only. All traces and events vanish on BEAM restart. Needs an optional persistent backend (SQLite via Ecto, or append-only file).

#### 17. Schedule Auto-Firing

Schedule handlers register their cron expression but never fire automatically. Only manual `trigger/1` works.

#### 18. Agent Nesting Inside Modules

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
| 3 | Capabilities & Effects | Capability declarations, compile-time checking, HTTP client, tracing |
| 4 | Handlers & HTTP | HTTP handlers with routing, request dispatch, Bandit + Plug server |
| 5 | Storage | ETS-backed `store.table` with get, put, delete, query |
| 6 | Agents | Agent state machines, phases, transitions, memory, LLM, tools, events |
| 7 | Testing & CLI | Test constructs, full CLI (new, build, test, run, trace) |

### Infrastructure (Phase 8)

| Sub-phase | Name | Summary |
|-----------|------|---------|
| 8a | Test Infrastructure | Scenario tests (`given`/`expect`), golden trace tests, replay engine |
| 8b | Storage Backend | Ecto schema generation, migrations, SQLite via `ecto_sqlite3` |
| 8c | HTTP Server | Bandit + Plug integration, `req.json[T]` body validation |
| 8d | Canonical Examples | 11 working `.skein` programs with integration tests |
| 8e | Queue & Schedule | `handler queue` and `handler schedule` constructs |
| 8f | LLM Streaming | `llm.stream` with chunked responses and trace spans |

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

21 error codes + 3 warning codes, all aligned with the language specification. Every error includes `code`, `severity`, `message`, `location`, and `fix_hint`.

### Editor Tooling

- **VS Code extension** with TextMate grammar, 30+ snippets, LSP client
- **Language Server** (GenLSP): diagnostics, document symbols, hover, go-to-definition, completions, semantic tokens

### Distribution

- **Burrito binaries** for Linux x86_64, macOS x86_64, macOS ARM64
- `skein build --output` writes `.beam` files to disk
- See [Distribution](/Skein/roadmap/distribution/) for remaining packaging work
