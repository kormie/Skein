# Skein Project Memory

## Project State (v1.0.0 push — 2026-06-11 post-Beta session)
- Roadmap restructured on main: active gate is **v1.0.0 Release** milestone (release train v0.2.0 -> v0.3.0 -> rc -> 1.0); post-1.0 backlog keeps #145 #150 + v1.2/Future
- Milestone cleanup (2026-06-11, pre-v0.3.0): renamed Alpha->**v0.1 Alpha Release**, Beta->**v0.2 Beta Release** (both `state: closed`), Post-MVP 1->**v1.1: Hardening & Language**, Post-MVP 2->**v1.2: Interop & Agent Workflows**; milestones.yml now syncs title (renames via `previous_titles`) and `state`; #114 moved Post-MVP 1 -> Beta (its fix shipped in v0.2.0)
- Post-Beta session merged: #114 Int interpolation (PR #153), #121 queue/topic subscription (PR #158), #118 ETS ownership (PR #161), #147 match guards (PR #164)
- **v1.0.0 milestone CLEARED in this session**: #154 (PR #165 schema-directed llm.json atomization), #146 (PR #166 embed span meta + stub e2e + Voyage docs), #156 (PR #168 EventLog facade deleted, LSP annotation completions aligned to spec 4.2), #157 (PR #169 docs/STABILITY.md), #155 (spec freeze — owner decisions recorded on the issue: timer bodies IMPLEMENTED, tuple destructuring + planned-testing block REMOVED from 1.0 spec)
- Next: v1.0.0-rc per the roadmap release train (full docs/spec sweep), then rc soak; post-1.0 backlog starts at #145 (llm.rerank) and #150 (code actions phase 2)
- Timer task bodies: Timer.after/5 + interval/5 (group, ms, task, work, caps) store {:named_work, task, fun}; fire runs fun via Skein.Runtime.Process.start_supervised_task/1 (extracted from spawn/4 — the crash-isolation primitive); analyzer @effect_param_names gained timer.after/interval/cancel (named args now supported), @effect_optional_params gained timer work; codegen unchanged (scoped clause passes args through)
- Working cadence: single branch claude/post-beta-backlog-workflow-stfuu0, one PR per issue, squash-merge on green CI, stash + reset --hard onto fresh main between PRs (remote branch auto-deletes on merge — plain push recreates)

## Match Guards (#147 — 2026-06-11)
- `pattern if expr -> body`; `if` is CONTEXTUAL (ident token, parser-only) — parse_optional_guard between parse_pattern and expect(:arrow); guard expr parsed with parse_pipe_expr
- E0027 = invalid guard expression; @guard_safe_binary_ops [:+ :- :* comparisons :&& :||], unary [:not :negate]; division EXCLUDED (its codegen emits float/int dispatch case — not a valid Core Erlang guard); interpolated strings excluded (iolist_to_binary call)
- Non-Bool guard = E0020; guard checked via check_guard in infer_match_arm with pattern bindings bound
- Exhaustiveness: ALL coverage paths reject guarded arms (bool/enum/generic check_exhaustiveness heads, value_level_warnings W0004, codegen ensure_catch_all `is_nil(guard) and catch_all_pattern?`)
- Codegen: c_clause([pat], guard_expr, body) in BOTH generate_match_arm and generate_agent_match_arm; analyzer subset guarantees generate_expr output is guard-safe
- W0001: collect_referenced_identifiers Match clause now walks guards too
- Non-exhaustive runtime failure surfaces as Elixir CaseClauseError (not ErlangError) in tests

## ETS Table Ownership (#118 root cause — 2026-06-11)
- ETS tables die with their owner; lazy ensure_table created tables in WHATEVER process touched first (HTTP request procs, queue dispatch, agents, test procs) — mid-run table loss was the memory flake (put-then-get not_found, unreproducible locally)
- `Skein.Runtime.EtsTables` GenServer owns ALL named runtime tables (memory/store/event_store/timer/tool/idempotent/store_ecto registry); FIRST child of SkeinRuntime.Supervisor; --no-start fallback uses GenServer.start (UNLINKED — linked owner would die with transient starter); ensure_table retries :exit races
- Original suspects ruled out: every Memory.clear caller is namespace-scoped; all memory test files already async: false

## Project State
- **v0.2.0 RELEASED 2026-06-11** (PR #160 → auto-tag → binaries published) — packages the complete Beta milestone (7 issues, PRs #133–#139), repo hygiene (MIT license/CoC/security policy #131, one-line installer #132), and the #114 interpolation fix (#153). ALPHA shipped as v0.1.7 same day.
- Current version: 0.2.0 in mix.exs; latest release v0.2.0; VS Code extension 0.1.4 (ships the `.skein` file icon, PR #163)
- **v1.0.0 Release milestone is the active gate** (milestone number 6; defined in `.github/milestones.json` via PR #159; ROADMAP has "Path to v1.0.0" with release train v0.2.0 → v0.3.0 → v1.0.0-rc → v1.0.0). Gate status: bugs #114 ✓(#153) #121 ✓(#158) #118 ✓(#161) — open: #154 (llm.json string/atom key mismatch), #147 (guard expressions), #146 (embeddings backend), #155 (spec freeze on Planned annotations), #156 (deprecated-surface removal incl. EventLog facade), #157 (stability policy docs/STABILITY.md)
- Post-1.0 backlog: v1.1 (#145 #150), v1.2 (#141 #143 #144 #171), Future (#142 #148 #149); #78 tracks
- Test counts: verify from CI job logs (last memorized 1,774 + 202 after #139; #153/#158/#161/#163 landed since)
- Merge cadence: each PR squash-merged on green CI, branch reset onto main between PRs
- Elixir 1.19.5, OTP 28, managed by mise

## v1.0.0 Release Planning (2026-06-11 session)
- Milestone numbers: Alpha=1, Beta=2, Post-MVP1=3, Post-MVP2=4, Future=5, **v1.0.0=6**. GitHub MCP still has no milestone list/create tools — milestones.yml creates from JSON on merge; verify an `issue_write` milestone assignment by `issue_read` read-back of the milestone *title*
- Issues filed this session: #154 (llm.json results decode string-keyed but codegen field access uses `map_get(:atom,...)` — the pre-existing footgun from the #63 session, finally tracked), #155/#156/#157 (1.0 stability chores), #162 (vscode file icon, closed by #163)
- 1.0 principle baked into the gate: breaking removals (EventLog facade) and spec "Planned"-annotation decisions land BEFORE 1.0; STABILITY.md classifies surfaces (error codes append-only post-1.0, `__handlers__/0`-style metadata contracts, EventStore schema, skein.toml)
- VS Code file icon: `contributes.languages[].icon` {light, dark} → `icons/skein-file.svg` (docs-site logo, squared viewBox `-24 0 560 560`, stroke 44→56 for 16px legibility); language icons render under icon themes that support them (Seti fallback yes, "Minimal" no); vsce packaging verified locally (npm ci + npx vsce package works in the remote env)
- shields.io dynamic badges (release/downloads) intermittently show "Unable to select next GitHub token from pool" — shields-side GitHub-token-pool rate limiting, self-heals; static shields + GitHub-native workflow badges unaffected

## Replay Backend Injection (issue #73 — 2026-06-11, first Beta item)
- `Replay.with_replay/2` now actually intercepts effects: `active?/0` + validating `next_response/2` ({:ok,_} | {:mismatch,msg} | :exhausted | :no_replay); mismatch does NOT consume the event; with_replay normalizes atom- or string-keyed events and drops tool list/schema spans from the consumable sequence (registry reads re-execute live)
- `Llm.resolve_backend/0` swaps in `Llm.ReplayBackend` (new file llm/replay_backend.ex) when replay is active — validates model+method per call; errors are provider_error code "replay"
- `Trace.with_recorded_span/2`: fun returns {result, extra_meta} — extra merged into the span; used by Http and Tool.call so spans carry replayable payloads (http: response_body+status; tool/llm: response, full untruncated)
- Capability checks stay ahead of replay consumption in all three paths (denied calls don't eat recorded events)
- Exhausted trace = error, never a fallback live call; e2e test proves record→JSON-roundtrip→replay identical with FailingBackend installed
- Test export helper mirrors SQLite backend: drop `_key` (tuple, not JSON-encodable) before Jason round-trip

## Capability-Parameter Surface Decision (issue #69 — 2026-06-11)
- DECIDED (owner): Option B — "scoped capability labels" (spec §3.2): for memory.kv/event.log/process.spawn/timer the capability param names a scope label (namespace/stream/pool/group) the COMPILER threads into runtime calls; call sites unchanged (memory.kv was the existing precedent — codegen already extracts the first memory.kv namespace, core_erlang.ex ~1738)
- New E0017: duplicate scoped-capability declaration per module/agent (`check_duplicate_scoped_capabilities` in analyzer, uses `own_capabilities` so module+nested-agent labels don't false-positive; agent's label overrides module's inside the agent); parameterless declaration = unscoped (presence-only)
- Spec §6.11 "Background Work" now documents process.spawn/timer surface (was entirely absent from §6); E0013 remains documented-but-never-emitted
- Enforcement (#57) still open: codegen label threading for process/timer/event.log + runtime exact-label checks + property tests

## Scoped-Label Runtime Enforcement (issue #57 — 2026-06-11)
- PR #134 (E0017 spec decision, closes #69) security-audited (clean: labels are lexer literals; Jason/GenLSP/stderr sinks only; own_capabilities coverage complete) and merged on green CI
- `Capability.check_scoped(kind, label, caps)` is the shared permit/deny: no cap of kind → deny; any parameterless cap → permit anything (unscoped); else exact label ∈ params (nil label denied). Property pins it against randomized cap sets
- Runtime signatures are label-FIRST mirroring Memory: `Process.spawn(pool, task, caps)`, `Timer.after/interval(group, ms, task, caps)`, `Timer.cancel(group, ref, caps)`, `EventStore.log(stream, name, data, caps)` — old arities REMOVED (only codegen called them); EventLog facade keeps log/3 → log(nil, ...)
- Codegen: `@scoped_effect_capability_kinds` clause BEFORE the generic effect clause; `declared_scope_label/2` = first cap of kind, first param via capability_param_to_string, parameterless → nil. Agent-first capability ordering gives the §3.2 override for free (pinned by a nested-agent codegen test)
- Timer string tasks: compiled `timer.after(5000, "task")` previously could NOT run (is_function guard → FunctionClauseError); now `{:task, name}` named no-ops fire as trace spans — background_tasks.skein spawn/timer handlers are invokable and integration-tested
- Labels recorded: process span `pool:`, timer span `group:`, user_event `stream:` (nil when unscoped)
- spawn/3 has two clause shapes (pool/task vs fun/args) — keep them ADJACENT or ungrouped-clauses warning fails CI

## process.spawn Task Bodies (issue #74 — 2026-06-11)
- Surface: `process.spawn("name", &some_fn)` — second arg is a FnRef to a zero-param local fn; spec §6.11 documents it; timer bodies still Planned
- Runtime: `Process.spawn/4 (pool, task, fun, caps)` clause; codegen needed ZERO changes (the #57 scoped clause passes args through, so 2-arg calls land on spawn/4 with the lambda from FnRef codegen)
- Analyzer: `@effect_optional_params %{{"process","spawn"} => ["work"]}` — first optional effect param; `callee_param_names` returns a 4-tuple now; omitted trailing optionals drop out of the reordered args (only TRAILING params can be optional — middle omission would shift positions)
- Integration tests await background effects by polling (await/2 helper in core_erlang_test); crash-from-source test uses `1 / 0` (codegen emits :erlang.div → ArithmeticError in the Task, caller unaffected)

## Enum Value-Level Exhaustiveness W0004 (issue #76 — 2026-06-11)
- Pre-existing GAP fixed en route: enum-typed fn params resolved {:user_type, name} so check_exhaustiveness SKIPPED them entirely — `normalize_match_subject_type/2` maps declared enum names to {:enum, name} at the match site. E0024 now fires for param-typed subjects too (spec examples were already clean)
- Dotted variant patterns (`Event.Charge(n)`) previously poisoned coverage both ways: counted as wildcard in has_wildcard (unknown identifier) AND as uncovered in the covered set — `strip_enum_prefix/2` normalizes to bare variant names
- W0004 (`value_level_warnings/3`): fires per variant when no wildcard arm exists, the variant has an arm with any non-binding field pattern (not Identifier/Wildcard), and no all-bindings arm covers it; warning sits on the literal arm's pattern meta; fix_code "_ -> value"
- The Known Limitations entry about value-level exhaustiveness is now resolved

## LSP Code Actions (issue #108 — 2026-06-11, phase 1)
- `Skein.Lsp.CodeActions` (new file): per-code quickfix mapping answering from `Diagnostic.data` (string-keyed `code`/`fix_hint`/`fix_code`, set in diagnostics.ex) + document source — no recompile
- Mapped: E0001 missing-token (insert fix_code after the keyword extracted from "Missing 'X' after 'Y'"; diagnostic position IS the keyword start), E0012 (insert fix_code line after last `capability` line else after module/agent opening, indent copied), W0002 (delete whole line), W0001 (replace binding name found via word-boundary regex on the diagnostic's line with `_name`); everything else → no action
- server.ex: `code_action_provider: true` + TextDocumentCodeAction handler; diagnostics arrive back from the client as structs with string-keyed data — `field/2` helper reads structs OR wire maps
- GenLSP codeAction integration tests follow the server_test request/notify pattern; `mix test apps/skein_lsp` from umbrella root silently runs NOTHING (cd into the app or use umbrella-wide mix test)
- Phase 2 (Skein.Error span + edit_kind for generic application) moved to the post-MVP backlog

## Local LLM Backends (issue #107 — 2026-06-11, LAST Beta issue)
- `Llm.OpenAiCompatibleBackend` (config-tuple backend): chat/json/stream/embed with config last arg; model_map remaps capability model → local model (unmapped pass through); json = schema-in-prompt + fence strip (response_format rejected by several local servers); stream = single-chunk fallback; transport errors name the base_url
- **Llm chat/json did NOT dispatch {module, config} tuples before** (only stream/embed did) — call_chat/call_json added; call_embed tuple path now passes config through (was dropping it)
- Llm spans now carry `backend:` (module short name) + `base_url:` — resolve_backend() moved BEFORE with_enriched_span in chat/json/stream
- `Skein.CLI.Config`: hand-rolled TOML-subset parser (tables/dotted tables, quoted strings, ints, bools, inline string tables, comments; errors name the line); `llm_profile(parsed, env)` = env override else [llm] default; `apply_llm_profile` maps backend "anthropic"/"openai_compatible"/"test" → set_backend (openai_compatible requires base_url; api_key_env resolved via System.get_env)
- `--env` flag on run+test (env_flag_spec merged into both flag specs), SKEIN_ENV fallback; applied via apply_env_profile in test_all and do_run_config; scaffold skein.toml now has `[llm] backend="anthropic"` + commented dev block
- Stub OpenAI server tests: Bandit + module Plug with owner pid in plug opts (`plug: {StubServer, [owner: self(), respond: fun]}`), random port 10_000..60_000, requests echoed to test process
- Docs: runtime/local-models.md + sidebar entry
- CLI module is `Skein.CLI` (NOT SkeinCLI)

## Repo Hygiene / Issue Tracking (2026-06-10 audit session)
- All 20 open issues map to ROADMAP items (roadmap links each issue inline; 19 items across 4 tiers); #78 tracks the post-MVP backlog
- v0.1.5 field-testing wave (#101, #104–#109) triaged same day: #104 W0002/E0012 test-block gap, #105 assertion output, #106 git init, #107 local LLM backends, #108 LSP code actions, #109 MCP compile_check fidelity
- PR #102 MERGED 2026-06-10 20:37 → #100 closed (first Alpha item done): auto-tag on green version-bump merges (release.yml via workflow_call into build.yml), README badges, per-release docs snapshots; PR-run concurrency cancels superseded runs, never main/release builds
- Milestones-as-code: `.github/milestones.json` + `workflows/milestones.yml` (gh api, runs on push — any branch — when the JSON/workflow changes; syncs title/description/state, renames via `previous_titles`, never deletes). **v0.1 Alpha Release** = public-repo gate (#56 #63 #70 #71 #72 #77 #96 #100 #101 #104 #105 #106 #109); **v0.2 Beta Release** = #57 #69 #73 #74 #76 #107 #108 #114
- Issue forms in `.github/ISSUE_TEMPLATE/` (bug/feature/chore + config contact links) auto-label `type/*` + `status/triage`; triage flow + label glossary in CONTRIBUTING.md; PR template in `.github/pull_request_template.md`
- PR #53 (stale Feb repo-hygiene PR with generic templates) superseded by the 2026-06-10 hygiene PR and closed
- GitHub MCP has NO milestone create/list tools — the milestones.yml workflow is the only creation path; `issue_write` CAN assign an existing milestone by number (Alpha=1, Beta=2)
- Verify test counts from CI job logs (`get_job_logs` on the single "Format, compile, and test" job), not from memory — hex.pm can be unreachable in remote envs (deps.get fails on uncached packages, so `mix test` can't run locally)

## Cross-Module Tools (issues #79/#80/#81/#84, PRs #91/#93/#95/#97)
- Tools are the ONLY cross-module seam (#85, spec §3.1). Cross-module calls = `tool.call`.
- Codegen compiles each `implement` block to exported `__tool_impl_N__/1` (N = tool's declaration index); `__tools__/0` metadata carries `impl:` atom. Input fields bound via `map_get(atom, InputMap)`.
- `Skein.Runtime.Tool.register_module(mod)` reads `__tools__/0` and registers tools; idempotent (ETS set keyed by name). CLI compile/build/test/run all call it after loading a module.
- Expression-position variant construction exists now: `Ok(x)` → `{:ok, x}`, `Err(e)` → `{:error, e}`, `Enum.Variant(args)` → `{:variant, args...}`, `ErrName.from(e)` → `{:err_name, e}`. Guarded by uppercase-first-char (`binary_part(name, 0, 1) >= "A"` works in guards). Zero-field variants also construct now (#96): `Status.Active`, bare `Active`, and `Status.Active()` all lower to the bare snake atom (`:active`), matching patterns; unknown variants / wrong arity / wrong arg types are structured E0010/E0020 (check_variant_construction + unknown_constructor_error in analyzer).
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
- ~~Enum exhaustiveness is variant-level only~~ RESOLVED 2026-06-11 by #76: W0004 warns when a variant arm uses literal field patterns without a wildcard or all-bindings arm (see "Enum Value-Level Exhaustiveness W0004" section)

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

## Named Arguments in Calls (issue #56 — 2026-06-10)
- `AST.NamedArg{name, value, meta}`; parser two-token lookahead (`ident` `colon`) in `parse_args` — unambiguous, no expression starts that way
- Analyzer Pass 0a `resolve_named_args/2` runs BEFORE all other passes and **returns a rewritten AST** (analyze was pure-annotation before) — named args validated + reordered to positional, so codegen is untouched
- `@effect_param_names` maps `{namespace, method}` -> param names from spec §6 (llm/http/memory/topic/trace/process/event; tool.*/timer.*/stdlib unsupported → E0026)
- E0026 family: unknown name (fix_hint lists valid names, fix_code via closest_name), duplicate, positional-after-named, already-filled-positionally, missing params, unsupported callee
- Patterns reject named args at PARSE time (parse_pattern_args is separate from parse_args) — patterns can never contain NamedArg
- Generic AST rewrite walker: struct-reflection (skip :meta), lists, 2-tuples (`{:interpolation, e}` segments + MapLit `{key, e}` entries)
- StreamData permutations: `uniq_list_of` over small int ranges hits TooManyDuplicatesError — derive permutation from random sort keys with index tiebreak instead

## Agent Nesting Inside Modules (issue #63 — 2026-06-10)
- Parser: `agent` clause in parse_declaration → existing parse_agent; AST.Module.declarations can carry AST.Agent
- Analyzer: agent passes extracted to `run_agent_passes/2`; nested agents analyzed with `build_nested_agent_env` (module types/enums/caps merged, agent wins collisions; `:own_capabilities` keeps W0002 scoped to the agent's own decls; module W0002 counts nested-agent usage via `agent_decl_views`)
- Merged caps DEDUP structurally (`capability_dedup_key`) — same tool.use at module+agent level would otherwise trip E0015 duplicate short names
- **CoreErlang.generate/1 contract changed**: returns `{:ok, [{module_atom, binary}]}` (primary first, nested agents after); Compiler.compile_file/compile_string load all, return primary `{:module, mod}`; compile_to_binary returns the list; CLI build writes one .beam per entry
- Nested agent codegen: `generate_agent(ast, opts)` takes namespace/capabilities/type_decls; module atom `Skein.Agent.<Module>.<Agent>`; type_decls threaded into start/phase handler scopes (`__type_decls__`) so llm.json[T] schema resolution works in agent handlers (was missing even for top-level agents)
- Field access on llm.json results uses `map_get(:atom, map)` but backends return STRING keys — `.action` on a decoded result crashes (pre-existing; spec 8.4 `d.action` would crash at runtime) — now tracked as issue #154 (v1.0.0 milestone)
- Spec 8.4 now shows the nested shape; spec_examples_test's two 8.4 entries merged into one; `examples/market_research/single_file.skein` is the generated-from-two-files single-file variant

## Types Usable from Agents (issue #70 — 2026-06-10)
- Resolved BY #63: module types visible to nested agents; schema flows (codegen embeds SchemaGen.to_json_schema as literal → Llm.json/5 → backend.json/4 receives it) — verified with a test-local SchemaRecordingBackend (persistent_term capture)
- DECISION: agents never declare own `type` blocks; nesting is the one route (spec §3.7 prose added)
- Test-local backends implementing Skein.Runtime.Llm.Backend work fine with set_backend; reset via on_exit back to TestBackend
- Referencing runtime-compiled modules in tests warns "module not available" — use `Module.concat(["Skein", "Agent", ...])` to keep test compile warning-free

## Enum Variant Construction (issue #96 — 2026-06-10)
- Analyzer: FieldAccess clause for enum heads (declared-enum name + Uppercase field) BEFORE generic field access; bindings shadow enum names; data-variant-without-args is E0020 with `Enum.Variant(fields)` fix_code
- Bare uppercase identifiers in expr position: known variant → {:enum, E}; unknown → E0010 (Ok/Err exempt); bare TYPE names as expressions are now also E0010 (old analyzer_test used `Ok(Profile)` as a stand-in value — rewritten to a map literal; such programs never survived codegen anyway)
- Codegen: zero-arg constructor calls and no-call variant references lower to BARE ATOM (not 1-tuple) — must match pattern-side variant_pattern_atom; bare uppercase Identifier clause guarded `binary_part(name,0,1) in A..Z` before the generic var clause
- infer_type clause-grouping: new helpers must go AFTER the catch-all infer_type clause (ungrouped-clauses warning is an error in CI)

## Capability Checks in Test Blocks (issue #104 — 2026-06-10)
- `test_decl_views/1` wraps Test/Scenario(expect_body)/Golden bodies as Fn-shaped nodes; fed to check_capabilities (E0012) AND check_unused_capabilities (W0002) in the Module pass
- Scaffold warning-free is pinned by a CLI test (new_test.exs "scaffold sources analyze without warnings")

## Schedule Auto-Firing (issue #71 — 2026-06-10)
- Schedule GenServer: `compile_cron/1` (validated matcher: :any | MapSet per field), `cron_match?/2` (DOM/DOW OR rule, weekday 7→0), tick via :timer.send_interval (config `schedule_tick_ms` 1s, `schedule_auto_tick`), per-minute dedup keyed {y,m,d,h,min} per expr; `tick_at/1` injects a deterministic clock for tests
- config/config.exs sets `schedule_auto_tick: false` for config_env() == :test (wall-clock ticks would race deterministic tests)
- register/register_fn now return {:error, reason} for invalid crons (existing prop/statem generators only emit valid forms)
- Server.init registers `:schedule` entries from `__handlers__/0` — note: queue/topic subscribe have NO production call site (Server only wires HTTP + schedule); gap filed as issue
- trigger/1 stays dedup-free (manual test path)

## Agent emit -> EventStore (issue #72 — 2026-06-10)
- Handler results carry ONLY that invocation's events (codegen emits delta lists; `data.events ++ new_events` in agent.ex is correct, no double-count)
- `flush_events_to_store(result, data, phase)` runs BEFORE acting on the result in handle_init_result (:start) and handle_phase_result (current phase passed in from :execute_phase) — crash-safe
- Stored shape: kind: :user_event, event: name, data: fields-minus-:event, agent:, instance_id:, phase:, wall_time:
- skein_runtime tests can compile real Skein agents (Skein.Compiler available as test dep); await agent exit via Process.monitor before asserting

## skein new git init (issue #106 — 2026-06-10)
- cargo-style: init by default; skipped when inside a work tree (git rev-parse --is-inside-work-tree), --no-git, or git missing (app env :skein_cli :git_executable, :missing sentinel for tests); .gitignore ALWAYS written; no auto-commit
- new_test's repo tmp dir is inside the Skein work tree — git-init-happens tests must use System.tmp_dir!

## Structured Assertion Failures (issue #105 — 2026-06-10)
- `Skein.Runtime.AssertionError` (defexception op/left/right/expr/file/line + location/1); codegen __assert__ special-cases comparison BinaryOps (operands bound to vars, erlang op names: != -> :"/=", <= -> :"=<"), exception struct built as c_map with __struct__/__exception__ literals + runtime operand vars
- `render_source/1` in codegen: best-effort AST->source for failure headers (display only)
- CLI result maps gain optional :location ("file:line"); main.ex FAIL lines print it
- erlang:error(struct-with-__exception__) rescues as that exception in Elixir

## MCP compile_check Fidelity (issue #109 — 2026-06-10)
- `Compiler.check_file/1`: full pipeline (lex/parse/analyze/generate, NO load), returns {:ok, %{errors, warnings}} split by severity; lexer/parser error lists become check results, file-system problems stay {:error, message}
- MCP schema: ok = errors-only; warnings array added; project mode globs src/ + test/ (skein test discovery order)
- MCP docs page (editor/mcp-server.md) may mention the old schema — check on next docs sweep

## zsh Completions (issue #101 — 2026-06-10)
- `skein completions zsh` (CLI.completions/1 returns {:ok, script}); Main.usage_text/0 made public so the drift test asserts every help-listed subcommand appears in the script
- #118 flake recurred twice in local umbrella runs during this work (runtime suite, intermittent, targeted runs green)

## Spec Section 8 Sweep (issue #77 — 2026-06-10, LAST alpha issue)
- spec_examples_test upgraded: parse-only -> Compiler.check_file with ZERO diagnostics (errors AND warnings); writes examples to tmp files
- @effect_type_names (HttpError, StoreError, NotFound, MemoryError, LlmError, ToolError, ToolInfo, ToolName, PublishError, HttpResponse) added to @builtin_type_names — spec §6 effect types are language surface
- store.<table>.<method> usage now collected for W0002 (three-level FieldAccess clause + namespace_capability("store") -> "store.table")
- Spec 8.4 phase machine was genuinely broken (Analyze couldn't reach Failed; no Done handler) — fixed in spec + embedded copies
- Tuple destructuring marked Planned in grammar; agent.run_sync already gone

## Installer (2026-06-11, post-public)
- `/install.sh` (POSIX sh): platform detect, GitHub releases/latest/download URLs, sha256 verify vs checksums.txt, installs to ~/.local/bin; env overrides SKEIN_VERSION + SKEIN_BIN_DIR
- **SKEIN_INSTALL_DIR is RESERVED by Burrito** (the binary's wrapper reads it to relocate payload extraction) — installer must not use it; also `env -u` the SKEIN_* vars when invoking the binary post-install
- Served at https://kormie.github.io/Skein/install.sh via a cp step in deploy-docs.yml (single source: repo root)
- Verified end-to-end in-session against real v0.1.7/v0.1.6 releases (latest, pinned, bad-version exit 1)

## Known Bug Found 2026-06-10 (filed as issue)
- ~~**Int string interpolation emits raw codepoint**~~ FIXED 2026-06-11 by PR #153 (issue #114, shipped in v0.2.0): interpolation now coerces non-String values to their text form

## Error Code Alignment — COMPLETE
- All 22 error codes (E0026 named args added 2026-06-10) + 3 warning codes aligned with SKEIN_SPEC.md section 7
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
