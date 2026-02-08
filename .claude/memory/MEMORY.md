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

## What's Next
- Distribution work is unblocked — all three prerequisites are done
- Next priorities: Escript, OTP release generation, Burrito binaries, Hex.pm packages
- Post-MVP backlog: FFI, hot code upgrades, Web IDE, LSP, llm.embed, managed deployment

## Streaming Implementation Notes (Phase 8f)
- `llm.stream` uses same `model` capability as `chat`/`json`
- Backend behaviour has optional `stream/3` callback returning `{:ok, [chunks]}`
- `set_backend/1` accepts tuples `{module, config}` for dynamic backends in property tests
- CodeGen emits a no-op callback (`fun(_StreamChunk) -> ok`) for compiled Skein code
- DynamicStreamBackend + tuples pattern is useful for property testing any parameterized backend
