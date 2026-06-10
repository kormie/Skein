# Skein Project Memory

## Project State
- All phases complete (1-8f plus unified event store / Phase 10) — MVP reached
- Distribution prerequisites complete: enum variant matching, supervisors, build --output
- Current version: 0.1.5 (released 2026-06-10: binaries for 4 targets incl. linux-aarch64, skein-vscode.vsix, checksums; `v*` tag push triggers build.yml release)
- Test counts on main @ v0.1.5, from CI job logs: 1,547 tests + 195 properties (compiler 941+87, runtime 462+108, lsp 44, cli 100)
- Remaining work tracked in docs/ROADMAP.md (12 items, each linking its GH issue) + Alpha/Beta milestones
- Elixir 1.19.5, OTP 28, managed by mise

## Repo Hygiene / Issue Tracking (2026-06-10 audit session)
- All 13 open issues map to ROADMAP items (roadmap links each issue inline); #78 tracks the post-MVP backlog
- Milestones-as-code: `.github/milestones.json` + `workflows/milestones.yml` (gh api, runs on push when the JSON changes; never closes/deletes). **Alpha Release** = public-repo gate (#56 #63 #70 #71 #72 #77 #96 #100); **Beta Release** = #57 #69 #73 #74 #76
- Issue forms in `.github/ISSUE_TEMPLATE/` (bug/feature/chore + config contact links) auto-label `type/*` + `status/triage`; triage flow + label glossary in CONTRIBUTING.md; PR template in `.github/pull_request_template.md`
- PR #53 (stale Feb repo-hygiene PR with generic templates) superseded by the 2026-06-10 hygiene PR and closed
- GitHub MCP has NO milestone create/list tools — the milestones.yml workflow is the only creation path; `issue_write` CAN assign an existing milestone by number (Alpha=1, Beta=2)
- Verify test counts from CI job logs (`get_job_logs` on the single "Format, compile, and test" job), not from memory — hex.pm can be unreachable in remote envs (deps.get fails on uncached packages, so `mix test` can't run locally)

## Cross-Module Tools (issues #79/#80/#81/#84, PRs #91/#93/#95/#97)
- Tools are the ONLY cross-module seam (#85, spec §3.1). Cross-module calls = `tool.call`.
- Codegen compiles each `implement` block to exported `__tool_impl_N__/1` (N = tool's declaration index); `__tools__/0` metadata carries `impl:` atom. Input fields bound via `map_get(atom, InputMap)`.
- `Skein.Runtime.Tool.register_module(mod)` reads `__tools__/0` and registers tools; idempotent (ETS set keyed by name). CLI compile/build/test/run all call it after loading a module.
- Expression-position variant construction exists now: `Ok(x)` → `{:ok, x}`, `Err(e)` → `{:error, e}`, `Enum.Variant(args)` → `{:variant, args...}`, `ErrName.from(e)` → `{:err_name, e}`. Guarded by uppercase-first-char (`binary_part(name, 0, 1) >= "A"` works in guards). **Call forms only**: zero-field variants (`Status.Active` field-access form, bare `Active`) still fail (misleading E0020 / core_lint unbound_var), and unknown-variant/wrong-arity constructor calls crash codegen unstructured — issue #96 / ROADMAP item 4.
- `variant_pattern_atom("Err")` → `:error` (NOT `:err`) — patterns and constructors align with runtime `{:ok,_}/{:error,_}`.
- Parser REQUIRES `implement` block on every tool (E0001 without it) — `impl: nil` only possible in hand-rolled metadata.
- `Http.post/put/patch` accept map bodies (JSON-encoded). Map body + no `http.out` capability = deterministic offline denial (capability checked inside the Trace span, after encoding).
- `memory.get` returns `{:ok, v}/{:error, "not_found"}` — examples must unwrap with `!` (spec RefundAgent uses `memory.get!`). Same for `llm.chat`.
- `skein test` (`test_all/1`) is two-phase: compile+load ALL of src/ then test/ (registering tools), THEN run tests.
- `skein new` scaffolds: co-located `test` block in src/main.skein + `{Module}.Greet` tool + test/ integration test via `tool.call(...)!`.
- examples_test drives market_research e2e: register service tools → agent `__phase_handler__(:gathering, %{}, [])` → suspend; trace `:http` span proves the implement executed (absent span = registration regression).
- Agent memory key scoping is process-dictionary based (`:skein_agent_name`/`:skein_agent_instance_id`) — direct handler calls from tests are unscoped.
- CI workflows only trigger on PRs based on `main`; retargeting a PR's base does NOT trigger CI (push an empty commit for a `synchronize` event). `workflow_dispatch` is 403 for the integration token.

## Key Patterns
- Tests must use `--no-start` or run via `mix test` (umbrella)
- Module names: `Skein.User.{Name}` for modules, `Skein.Agent.{Name}` for agents
- All test constructs (test/scenario/golden) use `__test_N__/0` functions and `__tests__/0` metadata
- Trace.init/0 uses try/rescue around ETS creation for concurrent safety
- Parser uses `expect_ident_value` for contextual keywords (from, trace)
- Parser targeted errors: known section/entry name + wrong following token → `missing_token_after_error` ("Missing ':' after 'description'", fix_code ":"); `expect/3` messages print source text (':' not 'colon'); `unexpected_token_error/4` takes explicit fix_code
- `compile_string/1` is the test helper for integration tests
- `compile_file/1` is the integration test helper for .skein file examples

## CLI / LSP Learnings (2026-06-10 UX pass)
- `SkeinLsp.start/0` was broken until 0.1.3: GenLSP 0.11 needs Buffer (stdio comm) + Assigns + Task.Supervisor wired explicitly; `communication:` is a Buffer option, not a GenLSP one
- `skein lsp` subcommand: must route :logger default handler to standard_error (LSP owns stdout)
- LSP tests use GenLSP.Test (TCP buffer) so they never exercised the stdio boot path — smoke-test stdio with a framed initialize request via `mix skein.lsp`
- CLI messages must be ASCII — em-dashes print as \x{2014} when stdout is latin1
- VS Code commands need BOTH registerCommand and package.json contributes.commands to appear in the palette
- Burrito release apps list lives in root mix.exs releases(); skein_lsp added 0.1.3
- Compiler errors get their file path from Parser.parse(tokens, path) meta; lexer errors are stamped after the fact in Skein.Compiler

## Key Technical Details
- Prefix unary minus is `%AST.UnaryOp{op: :negate}` — parser `parse_unary_expr` minus clause, analyzer types it Int→Int/Float→Float (E0020 otherwise), codegen calls `erlang:'-'/1`. No negative-literal token; binds tighter than binary arithmetic.
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
- Runtime Queue/Topic/Schedule/Timer/Process: supervised under SkeinRuntime.Application; `ensure_started/0` remains as a race-safe fallback for --no-start environments
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
- decimal needs override: true at the umbrella root

## Audit 2026-06-09 Resolutions (all Critical/Major fixed)
- Store/Memory use SINGLE static ETS tables (`:skein_store` keyed `{table, id}`, `:skein_memory` keyed `{namespace, key}`) — never String.to_atom on table/namespace names
- Router whitelists HTTP methods (405 for unknown) — never String.to_atom on wire input
- EventStore is size-bounded: `:event_store_max_events` config (default 100k), oldest evicted on append
- StoreEcto.query validates filter keys against schema fields before `field(r, ^key)`
- CI: `.github/workflows/ci.yml` enforces format/compile --warnings-as-errors/tests
- All parser/lexer errors carry fix_code (token_text/1 and default_fix_code/1 helpers in parser)
- gen_var counter resets at each CodeGen.generate/1 entry (still process-dictionary based)

## Common Issues
- ETS race condition: Always wrap `:ets.new` in try/rescue when called from multiple processes
- Property tests: Avoid generating keywords as identifiers (prefix with "z")
- Codegen scope threading: Given vars must be in scope when generating expect body
- Parser: `from` and `trace` in golden tests are identifiers, not keywords
- GenServer cleanup race: `on_exit` callbacks may run after GenServer dies — wrap in try/catch :exit
- Schedule/Queue nil handling: method is nil for non-HTTP handlers, param is nil for schedule handlers
- Hex.pm availability varies by environment: deps are declared as hex packages; if hex is unreachable, switch to git deps with override: true
- exqlite NIF: Compiles from C source when precompiled binary unavailable — needs gcc
- gen_lsp: `lsp.assigns` is the Assigns agent PID, NOT a map — read state via `assigns(lsp)`
- gen_lsp: buffer calls System.stop() on transport close unless `config :gen_lsp, :exit_on_end, false` (set in skein_lsp test_helper)
- LSP integration tests use GenLSP.Test (server/client/request/notify/assert_result) over real TCP — needs generous assert_receive_timeout

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
- **ROADMAP.md** (`docs/ROADMAP.md`) is the canonical prioritized work list (rewritten 2026-06-10 against a source-verified status pass)
- Top open items: named arguments in calls, agent nesting inside modules, types usable from agents, schedule auto-firing, agent emit -> EventStore, replay backend injection
- Type inference, schema derivation, Anthropic backend, instance-scoped memory, error context/fix_code, tool validation, contextual keywords, persistent EventStore are all DONE (don't re-litigate)
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

## Demo-Readiness Session (2026-06-10)
- Release flow: a PR bumps `mix.exs` + `apps/skein_cli/mix.exs` and dates CHANGELOG.md, then an annotated `v*` tag at the merge commit triggers build.yml (binaries + vsix + GitHub Release). v0.1.2–v0.1.5 all released 2026-06-10. Auto-tagging green merges is issue #100.
- Test counts: see Project State (kept current there only)
- **Model IDs**: canonical example model is `claude-opus-4-8` (capability form: `model("anthropic", "claude-opus-4-8")`). Never use `claude-sonnet-4-20250514` (deprecated, retires 2026-06-15). AnthropicBackend no longer rewrites gpt-* names — model passes through unchanged.
- **String-literal match patterns**: pattern position needs `c_binary` with per-byte `c_bitstr` segments — a binary `c_literal` crashes core_to_ssa on OTP 28. Non-exhaustive matches need an explicit case_clause-raising catch-all clause (`ensure_catch_all` in codegen) or beam_validator rejects binary patterns.
- **`method!(args)` parsing**: bang/question followed by lparen is handled in `parse_postfix_chain` (parse call first, wrap UnaryOp unwrap/propagate, continue chain). Plain postfix `!`/`?` after a complete chain still handled in `parse_unary_expr`.
- **`state.field` in nested positions**: generate_expr has a clause keyed on `%{__state_var__: sv}` scope (guarded by `not is_map_key(scope, "state")` so user bindings win).
- **store.get!/put!**: in analyzer `@store_methods`, codegen store guard, and `Skein.Runtime.Store.get!/3, put!/3`. Compiled `.get!(id)` actually goes through unwrap-of-call + `Store.get/3` (raises ErlangError on miss via erlang:error).
- **Capability rename**: `queue.consume` / `schedule.trigger` (was queue.in/schedule.in). Declaring an old name gets a rename hint on E0012 (`deprecated_capability_alias` in analyzer). Spec grammar now lists schedule.trigger.
- **process.spawn("name")**: string clause spawns a supervised no-op task (task name in trace span); task bodies are a roadmap item. event.log param-level runtime checks blocked on surface design (capability param is a stream label, call carries event name) — documented in ROADMAP item 7.
- `examples/README.md` is the example index; examples_test covers all 14. `compile_string` success returns `{:module, mod}` (not `{:ok, mod}`).
- llm.embed has no real backend (Anthropic has no embeddings API) — semantic_search example declares voyage model and documents this.

## Agent Context Injection (issue #89 — 2026-06-10)
- `skein new` scaffolds AGENTS.md (+ CLAUDE.md pointer); `--no-agents` skips; `skein agents` regenerates only the `<!-- skein:generated:start/end -->` block, preserving user content
- Primer single source: `docs/site/src/content/docs/reference/agent-primer.md` — embedded into `Skein.CLI.AgentsMd` at compile time via `@external_resource` (body = from first `## ` heading, drops frontmatter/intro)
- `skein mcp`: hand-rolled newline-delimited JSON-RPC stdio server in `Skein.CLI.Mcp` (no deps); SKEIN_SPEC.md embedded at build time, parsed into sections cached in :persistent_term
- MCP tools: skein_spec_lookup (number or title fragment), skein_docs_search, skein_compile_check (Jason-encodes %Skein.Error{} directly — @derive Jason.Encoder)
- mcp/lsp subcommands both must route :logger default handler to stderr (they own stdout)
- Docs: editor/mcp-server.md + reference/agent-primer.md, both in astro.config.mjs sidebar
