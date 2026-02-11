# Skein Project Memory

## Project State
- Phases 1-7 + 8a + 8b + 8c + 8d + 8e + 8f are complete (all Phase 8 subphases done)
- Distribution prerequisites complete: enum variant matching, supervisors, build --output
- All core phases complete — MVP reached
- Elixir 1.19.5, OTP 28, managed by mise

## Key Patterns
- Tests must use `--no-start` or run via `mix test` (umbrella)
- Module names: `Skein.User.{Name}` for modules, `Skein.Agent.{Name}` for agents
- All test constructs (test/scenario/golden) use `__test_N__/0` functions and `__tests__/0` metadata
- Trace.init/0 uses try/rescue around ETS creation for concurrent safety
- Parser uses `expect_ident_value` for contextual keywords (from, trace)
- `compile_string/1` is the test helper for integration tests
- `compile_file/1` is the integration test helper for .skein file examples

## Key Technical Details
- `input` is a keyword token in Skein — use `ctx` or typed params in agents
- `stop` must be called as `stop()` with parens in agent handlers
- Handler AST: `%Handler{source, method, route, param, body, meta}` — `method` is nil for queue/schedule
- Test files run from app dirs — use `Path.join(__DIR__, "..", "..", "..", "..")` for project-root-relative paths
- GenServer `reset_all/0` in tests needs try/catch for exit races in `on_exit` callbacks
- `mix format` auto-runs and may reformat test files
- Agent `on start` requires typed parameters: `on start(order_id: String)`, not `on start(ctx)`

## Architecture Notes
- Parser: `parse_handler` branches on source type (http/queue/schedule)
- Analyzer: `handler_required_capability/1` maps source -> capability name (http.in/queue.in/schedule.in)
- CodeGen: `__handlers__/0` includes `source` field (:http, :queue, :schedule)
- Runtime Queue/Schedule: GenServer-based, self-starting via `ensure_started/0`
- Compilation: `compile_file/1` and `compile_string/1` in `Skein.Compiler`
- Analyzer helper functions must come after all clauses of a `validate_declaration` defp to avoid ungrouped clauses warning

## Storage Backend (Phase 8b)
- `Skein.Runtime.EctoSchema` — dynamically creates Ecto schema modules from field maps
- `Skein.Runtime.MigrationGen` — generates and executes Ecto migrations
- `Skein.Runtime.StoreEcto` — Ecto-backed get/put/delete/query with upsert (ON CONFLICT DO UPDATE)
- `Skein.Runtime.Repo` — SQLite3 via `ecto_sqlite3`
- Schema registry: ETS table `skein_store_ecto_schemas` maps table names -> schema modules
- Changeset must cast ALL fields including primary key (autogenerate: false)
- Ecto tests need `async: false` and explicit Repo start/stop with try/catch for cleanup
- Type mapping: String→:string, Int→:integer, Float→:float, Bool→:boolean, Uuid→:binary_id, Instant→:utc_datetime
- Dependencies: ecto v3.12.5, ecto_sql v3.12.1, ecto_sqlite3 v0.17.5, exqlite v0.24.2
- All git deps with override: true (no hex.pm access in this env)

## Common Issues
- ETS race condition: Always wrap `:ets.new` in try/rescue when called from multiple processes
- Property tests: Avoid generating keywords as identifiers (prefix with "z")
- Codegen scope threading: Given vars must be in scope when generating expect body
- Parser: `from` and `trace` in golden tests are identifiers, not keywords
- GenServer cleanup race: `on_exit` callbacks may run after GenServer dies — wrap in try/catch :exit
- Schedule/Queue nil handling: method is nil for non-HTTP handlers, param is nil for schedule handlers
- Hex.pm unreachable: All dependencies must be git-based with override: true
- exqlite NIF: Compiles from C source when precompiled binary unavailable — needs gcc

## File Locations
- Parser: `apps/skein_compiler/lib/skein/parser.ex`
- Analyzer: `apps/skein_compiler/lib/skein/analyzer.ex`
- CodeGen: `apps/skein_compiler/lib/skein/codegen/core_erlang.ex`
- Runtime Queue: `apps/skein_runtime/lib/skein/runtime/queue.ex`
- Runtime Schedule: `apps/skein_runtime/lib/skein/runtime/schedule.ex`
- Ecto Schema: `apps/skein_runtime/lib/skein/runtime/ecto_schema.ex`
- Migration Gen: `apps/skein_runtime/lib/skein/runtime/migration_gen.ex`
- Store Ecto: `apps/skein_runtime/lib/skein/runtime/store_ecto.ex`
- Repo: `apps/skein_runtime/lib/skein/runtime/repo.ex`
- Examples: `examples/` (hello.skein, hello_http.skein, refund_agent.skein, incident_triage.skein, queue_worker.skein)
- Examples Tests: `apps/skein_compiler/test/skein/examples_test.exs`
- Docs site: `docs/site/src/content/docs/`
- Sidebar: `docs/site/astro.config.mjs`

## User Preferences
- Use mermaid diagrams for human-focused docs, DOT for LLM docs
- TDD is mandatory — write tests before implementation
- Property tests (StreamData) required where inputs have wide spaces
- The compiler should validate all Phase enum clauses have `on phase` handlers (already done: E0032)

## Known Limitations / Future Work
- **Enum exhaustiveness is variant-level only**: The analyzer checks that all *variant names* are covered in a match, but does NOT check exhaustiveness of values *within* variant fields. E.g., `match e { Event.Charge(5) -> "five" }` satisfies the "Charge variant is covered" check, but at runtime a `case_clause` error occurs for `Event.Charge(10)`. This could cause unexpected crashes. A future improvement could warn when a variant arm uses literal patterns without a wildcard fallback. See `check_exhaustiveness/4` in `analyzer.ex` lines 903-951.

## Distribution Prerequisites (Completed)
- **Enum variant matching**: codegen supports `%AST.Call{}` patterns in `generate_pattern/2`, producing tuple patterns `{:variant_atom, Arg1, ...}`. Uppercase identifiers in pattern position match as atoms.
- **Supervisor declarations**: Parser handles `supervisor Name { child Target { opts } strategy: ... max_restarts: N per Ms }`. Codegen exposes `__supervisors__/0` metadata. Analyzer validates strategy, max_restarts, and warns on empty children.
- **`skein build --output`**: `CLI.build/1` accepts `--output <dir>` flag. Uses `Compiler.compile_to_binary/1` to get module name + binary, writes `.beam` files to disk.
- `to_snake_case/1` helper in codegen converts CamelCase variant names to snake_case atoms
- `variant_pattern_atom/1` strips enum prefix from dotted names (e.g., "Event.Charge" -> :charge)
- `decimal` dependency needed override at umbrella root level (`mix.exs`), not just in child app

## Standard Library (Stdlib) — COMPLETE
- All 11 modules implemented: String, Int, Float, List, Map, Set, Option, Result, Uuid, Instant, Duration (101 functions)
- Stdlib registry: `@stdlib_registry` in analyzer maps `{Module, function}` -> `{params, return_type}`
- Stdlib codegen: `@stdlib_modules` in codegen maps Skein module name -> runtime Elixir module
- Runtime modules: `apps/skein_runtime/lib/skein/runtime/stdlib/*.ex`
- Stdlib calls don't require capabilities — `collect_effect_calls` naturally skips them (not in `@effect_namespaces`)
- Codegen clause for stdlib must appear BEFORE `respond.json` and other effect clauses in `generate_expr`
- `types_compatible?` extended for parameterized types: `{:list, :unknown}` matches `{:list, :int}` etc.
- FnRef codegen fixed: generates lambda wrapper for known local functions so `&fn_name` works with higher-order List functions
- Tests: `stdlib_test.exs` (1a), `stdlib_collections_test.exs` (1b+1c), `stdlib_types_test.exs` (1d+1e)
- Option: `{:some, value}` / `:none`; Result: `{:ok, value}` / `{:error, reason}`
- Set backed by MapSet; Uuid uses `:crypto.strong_rand_bytes` + Bitwise; Duration is integer seconds
- Instant is ISO 8601 string backed by DateTime

## Error Code Alignment — COMPLETE
- All 21 error codes + 3 warning codes aligned with SKEIN_SPEC.md section 7
- Key renumberings: E0011→E0024, E0012→E0020, E0021→E0020, E0024→E0021, capability E0030→E0012, tool E0031→E0014, tool E0032→E0015
- New codes: E0011 (duplicate def), E0022 (!on non-Result), E0023 (?on non-Result), W0001 (unused binding), W0002 (unused capability), W0003 (unreachable after stop)
- Analyzer now returns `{:ok, ast, warnings}` for warnings-only (previously `{:error, warnings}`)
- All callers of `Analyzer.analyze/1` must handle the 3-tuple `{:ok, ast, warnings}` return shape
- Test helpers use `analyze_ok!` pattern: `defp analyze_ok!({:ok, ast}), do: ast; defp analyze_ok!({:ok, ast, _}), do: ast`
- AST.Block uses `expressions` field, NOT `exprs`
- `stop()` is parsed as `AST.Stop` node, NOT `AST.Call`

## What's Next
- **ROADMAP.md** (`docs/ROADMAP.md`) is the canonical prioritized work list
- Phases 1-10 + all UP_NEXT priorities are COMPLETE
- Top priorities now: real type inference (field access, pattern bindings), spec-example alignment, runtime capability enforcement
- See `docs/AUDIT_FIRST_PRINCIPLES.md` for the detailed gap analysis behind the roadmap
- `docs/IMPLEMENTATION_PLAN.md` and `docs/UP_NEXT.md` were deleted (fully completed, outdated)

## Topic Pub/Sub (Priority 5 — COMPLETE)
- `handler topic "name" (msg) -> { ... }` parsed by `parse_topic_handler`
- Analyzer: `handler_required_capability("topic") -> "topic.consume"`, `@effect_namespaces["topic"] -> "topic.publish"`, `@effect_methods["topic"] -> ["publish"]`
- Codegen: `@effect_runtime_modules["topic"] -> Skein.Runtime.Topic`, generates `Topic.publish(name, data, capabilities)`
- Runtime: `Skein.Runtime.Topic` GenServer, fan-out to all subscribers (broadcast), same pattern as Queue
- `topic.publish(name, data)` is the effect call; `topic.consume` capability for handlers
- Example: `examples/pubsub_notifications.skein`
- Runtime Topic: `apps/skein_runtime/lib/skein/runtime/topic.ex`

## Idempotent(key) (Priority 6 — COMPLETE)
- `idempotent(key)` parsed as `AST.Idempotent` node with `:key` and `:meta` fields
- Analyzer: E0035 error for `idempotent()` outside handler body (valid in handlers only, not fns)
- Codegen: generates `Skein.Runtime.Idempotent.check!(key)` call
- Runtime: ETS-backed key tracking with configurable TTL (default 1 hour)
- `check!/1` throws `{:idempotent_skip}` for duplicate keys; Handler/Queue/Topic catch it
- Handler dispatch returns `{:ok, 200, "already processed", :json}` on skip
- Queue/Topic dispatch silently drops the message on skip
- Runtime Idempotent: `apps/skein_runtime/lib/skein/runtime/idempotent.ex`
- Example: `examples/queue_worker.skein` uses `idempotent(msg.id)`
- Can't use `ttl_ms()` in guard clauses — must bind to variable first

## Remaining Capabilities (Priority 9 — COMPLETE)
- `process.spawn` → namespace `process`, capability `process.spawn`, runtime `Skein.Runtime.Process` (DynamicSupervisor)
- `timer` → namespace `timer`, capability `timer`, runtime `Skein.Runtime.Timer` (GenServer + ETS)
  - `timer.after` is an Elixir reserved word: uses `def unquote(:after)(...)` syntax, tests use `apply(Timer, :after, [...])`
  - Timer methods: `after`, `interval`, `cancel`
- `event.log` → namespace `event`, capability `event.log`, runtime `Skein.Runtime.EventStore` (unified event log)
  - Method: `log`
- All three follow the standard effect pattern: added to `@effect_namespaces`, `@effect_methods`, `@effect_runtime_modules`
- Examples: `examples/background_tasks.skein`, `examples/audit_log.skein`
- Runtime Process: `apps/skein_runtime/lib/skein/runtime/process.ex`
- Runtime Timer: `apps/skein_runtime/lib/skein/runtime/timer.ex`
- Runtime EventStore: `apps/skein_runtime/lib/skein/runtime/event_store.ex`
- Runtime EventLog: `apps/skein_runtime/lib/skein/runtime/event_log.ex` (deprecated — delegates to EventStore)

## Unified Event Store (Phase 10 — COMPLETE)
- **Single event log**: `Skein.Runtime.EventStore` backed by one ETS table `:skein_events`
- **Event kinds**: `:effect`, `:annotation`, `:user_event`, `:state_change` (plus effect-specific kinds like `:http`, `:memory`, etc.)
- **Trace facade**: `Skein.Runtime.Trace` delegates to EventStore — `with_span`, `annotate`, `recent_spans` all use `EventStore.append`
- **EventLog deprecated**: `Skein.Runtime.EventLog` is a thin redirect to EventStore; codegen now points `"event"` → `EventStore`
- **Memory event-sourced**: Each `memory.put`/`memory.delete` emits a `:state_change` event; `Memory.rebuild_from_events/1` reconstructs state
- **Replay enhanced**: `Replay.rebuild_memory/2` reconstructs memory from event stream; handles `state_change`, `user_event`, `annotation` kinds
- **One way to query**: `EventStore.query(kind: :user_event)` — no parallel query APIs

## Streaming Implementation Notes (Phase 8f)
- `llm.stream` uses same `model` capability as `chat`/`json`
- Backend behaviour has optional `stream/3` callback returning `{:ok, [chunks]}`
- `set_backend/1` accepts tuples `{module, config}` for dynamic backends in property tests
- CodeGen emits a no-op callback (`fun(_StreamChunk) -> ok`) for compiled Skein code
- DynamicStreamBackend + tuples pattern is useful for property testing any parameterized backend
