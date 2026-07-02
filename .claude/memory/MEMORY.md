# Skein Project Memory

## Project State (v1.0.0-rc.5 milestone IMPLEMENTED — 2026-07-02 session; PR #337 MERGED, bump owner-gated)
- **All 4 rc.5 issues closed** (#334 verified-no-repro, #320 + #332 + #336 via merged PR #337 — one commit per issue, true merge not squash, merge commit 429e94e). Milestone **v1.0.0-rc.5 — True release candidate: zero open issues.** mix.exs still 0.5.0 — the rc.5 bump is the OWNER's call (bump-version skill); after tagging the candidate SOAKS — do NOT promote to v1.0.0 or start GA work without explicit direction. Umbrella after everything: **2,601 tests + 210 properties, 0 failures** (compiler 1,541+94 / runtime 789+115 / LSP 60 / CLI 211+1).
- **#334 llm.stream**: does NOT reproduce live (probe: exact dogfood prompt 1.3s/2 chunks, long stream 48.5s/96 chunks/10.2KB, compiled-Skein path 1.5s; model claude-opus-4-8). Root cause (receive loop matching the Req.Response.Async STRUCT instead of its ref → 120s inactivity timeout) was fixed by the AsyncBody rework (#178) and is regression-pinned by the stub SSE tests. Closed with the live result on the issue + note on kormie/skein-testing#26. **ANTHROPIC_API_KEY is NOT in Bash env** — extract from the Claude session process: `/proc/<pid>/environ` of the claude process that has it (grep pgrep -f claude); never print it. api.anthropic.com is in no_proxy (direct connect works; Req doesn't read proxy env anyway).
- **#320 writability benchmark**: `mix skein.bench` (root alias; flags AFTER `--`: `mix skein.bench -- --live`) = Skein.CLI.Bench + Tasks/Recordings/History submodules. 12-task generate-compile-fix loop: AGENTS.md primer as system context (AgentsMd.primer/0 now public), check_string, mechanical apply_fix fixpoint, diagnostics-JSON feedback, cap 4. Replay mode default (deterministic, recordings at conformance/writability/recordings.json, pinned per-PR by bench_replay_test.exs); live mode records + appends conformance/writability/history.jsonl + regenerates docs/site/public/writability-history.svg (embedded in README Project Status + new docs page reference/writability-benchmark; sidebar entry added). On-demand GH workflow writability-bench.yml uses the ANTHROPIC_API_KEY repo secret (owner added it this session). Release-readiness toolchain-e2e step 5 runs the replay bench. Live measurements: run1 10/12 green 8/12 first-try → (after #336 fixes) 12/12 green, 9/12 first-try, mean 1.17. NOT part of the frozen CLI surface (deliberate — mix-alias only).
- **#336 (filed+fixed, the benchmark's teeth)**: Some/None in construction got dedicated E0010 messages (bare-inner-value/omit-field; patterns only) replacing a WRONG machine-applicable "replace Some→Timeout" fix (root cause: closest_name has no similarity threshold — new close_name_suggestion levenshtein-gates the constructor path; suggest_identifier's gate reused); `input.<field>` in tool implement steers to in-scope fields (env key :tool_input_fields added by check_tool_implement_inference) — canonical access is BARE field names (`amount`, not `input.amount`; `input` is CONTEXTUAL, `let input = 1` compiles — the primer's "input is a keyword" gotcha was STALE, now fixed); E0029 fix_code had `/* ... */` (not Skein!) → `scenario "..." { expect { ... } }`; scenario-body E0001 (bare assert) now steers to expect-block. Primer interpolation claims corrected (ident/dot-access only). Tests: analyzer_writability_diagnostics_test.exs (10).
- **#332 Wave F freeze**: frozen vectors under conformance/freeze/ + per-app freeze suites — compiler test/skein/freeze/ (keywords/diagnostics/effect_abi/json_schema/metadata — 20 tests), runtime event_store_freeze_test.exs, CLI cli_surface_freeze_test.exs + dogfood_pins_freeze_test.exs. Pattern: exact-equality vs vector, FREEZE_REGEN=1 regenerates+flunks for deliberate additive changes. Key facts: Skein.Lexer.keywords/0 added (23 reserved words); spec §2.3 contextual list CORRECTED (drops `replay` — nothing recognizes it; adds start/phase/from/trace/per/max_restarts; two-way drift-tested); §7 = 39 codes (E0001-3, E0010-17, E0020-43, W0001-4; E0013 severity "—"); Core-Erlang-built modules DON'T export module_info — use :erlang.get_module_info(mod, :exports), and __info__(:functions) hides underscore-prefixed fns; module dunders = __capabilities__/__handlers__/__tools__/__tests__/__supervisors__ (+__info__/1 + indexed __handler_N__/__tool_impl_N__/__test_N__), agent dunders = __phases__/__start_handler__/__phase_handler__ + start_link/1; EventStore reloaded events re-add internal :_key (drop it + id/timestamp when comparing shapes); persisted-shape vectors are Elixir literals IN the test (atom-vs-string keys unrepresentable in JSON); supervisor child syntax `child Name(Target) { max: 5, restart: permanent }`. STABILITY.md + site stability page + spec banner flipped to FROZEN-at-rc.5 (promises bind at 1.0 tag); EventStore row Pre-stable→Stable (also flipped in Persistence/EventStore moduledocs, ARCHITECTURE, runtime overview). Release-readiness GATES step 6 runs the freeze suites; version-staging is step 7 now.
- **#338 filed (v1.1)**: known flakes tracked — TopicTest global-registry emptiness race (hit this session on PR #337, re-kicked with empty commit; #271 family), Bedrock/Anthropic stub `:eaddrinuse` (Enum.random ports → bind port 0), analyzer_interpolation "EXIT killed" (rare, unreproduced).
- Session gotchas: `mix run` eats `--flags` — pass benchmark flags after `--`; Elixir mixed-key map literals need `=>` keys BEFORE atom-shorthand keys; `rescue` needs try-do inside anonymous fns in .exs; dataviz chart palette (blue #2a78d6 / aqua #1baf7a on #fcfcfb) validated via the dataviz skill; release-readiness workflow runs in THIS tree — don't run mix concurrently with it.
- **/release-readiness 1.0.0-rc.5 COMPLETE** (2 runs: first died mid-sweep on a usage-credits outage — 47/88 agents failed incl. all spec/example/meta-doc sweeps; RESUMED with resumeFromRunId after credits purchase, 92/92 done). All mechanical gates + all freeze suites + full umbrella GREEN; 4 CONFIRMED content blockers + 9 CONFIRMED warnings, ALL FIXED on PR #339 (stale README 0.4.0 posture, spec 'not yet frozen' FOOTER at EOF — flip BOTH banner and footer when freezing!, CONTRIBUTING intro, runtime-overview 3-arg memory.put example, codegen.md put/5, capabilities-table uuid/instant, types.md TypeRef params, writability-page 'exactly the primer' overclaim, stdlib '101 functions' count, spec §4.1 Json row, ROADMAP B6 stale line cites, ARCHITECTURE EffectABI mention, CLAUDE.md tree bench/conformance). Remaining NO_GO driver = version-staging gate only (owner-gated bump). Also on #339: **#340 store @primary blocker** (third-party review finding, source-verified: Store.put hard-coded id extraction while spec/analyzer allow any single @primary — codegen now threads the primary field name, Store.put/5; sku-primary e2e round-trip pinned) + spec §6.2 store.table(name, RecordType) header fix + #338 filed (v1.1 flake tracking: TopicTest global-registry race, stub-server Enum.random ports, analyzer_interpolation EXIT). NEXT: owner decides the rc.5 bump (bump-version skill); after tagging the candidate SOAKS.

## Project State (v0.5.0 milestone IMPLEMENTED — 2026-07-02 session, awaiting merge + tag decision)
- **All 10 v0.5.0 issues implemented on ONE batch PR #330** (branch claude/v0-5-0-runtime-contract-dzj7wl, one commit per issue with Closes lines): #262 dogfood gate, #296 C1, #297 C2, #279 C4 remainder, #298 C3, #255 C5, #299 C6, #325 supervisors, #314 generator widening, #315 factoring. Issues close when #330 merges. Umbrella after everything: **2,542 tests + 210 properties, 0 failures** (compiler 1,510+94 / runtime 788+115 / LSP 60 / CLI 184+1). mix.exs still 0.4.0 — the 0.5.0 bump/tag is the OWNER's call (bump-version skill); do NOT start rc.2/Wave F.
- **#262 dogfood gate**: both ports migrated (uuid.new() capability, nominal records, scenarios for tool.call, later typed store) — PRs kormie/skein-testing#36 + kormie/FablePool-skein#5 (open, tracked by this session's subscriptions). Checked-in corpus `conformance/dogfood/{dungeon,fablepool}` + machine-readable pins `conformance/dogfood.json` (exact expected test counts; dungeon 5, fablepool 18) run in every `mix test` via dogfood_corpus_test.exs; ci.yml `dogfood` job runs the corpus via CLI AND clones upstream at pins — **upstream half needs the DOGFOOD_GITHUB_TOKEN secret (ports are PRIVATE; owner asked on PR #330)**. When port PRs merge (squash), bump pins + refresh corpus copies. docs_fences_test.exs compiles every complete-module ```skein fence (error demos must emit annotated codes; `...`-blocks and non-`module Name {` starts are fragments); negative corpus asserts COMPLETE code sets + structured-diagnostic contract; Skein.Compiler.check_string/2 added.
- **C1 #296**: `Skein.EffectABI` = single registry (effects, store methods, provider contracts, ERROR ENUM variants); analyzer tables + codegen maps DERIVED from it; spec §6 signature lines drift-tested BOTH directions (effect_abi_test.exs — editing §6 or the registry alone fails); runtime ABI matrix (effect_abi_matrix_test.exs) pins every method's live shapes with completeness enforced. Contract fixes: timer.cancel → Result[String,String] ({:ok, ref}, idempotent), event.log → Result[String,String] ({:ok, name}).
- **C2 #297**: builtin error enums are REAL EnumDecls (builtin_enum_decls from EffectABI.error_enums; user decl shadows). Frozen ABI tuples (snake_case; zero-field = atom): LlmError (ParseFailed/Refused/RateLimit(ms Int)/Timeout(ms Int)/ContentFiltered/InvalidSchema/ProviderError/Denied), ToolError (NotFound/ValidationError/ExecutionError/Denied), HttpError (+InvalidRequest/Denied), Store/MemoryError (NotFound/Failed/Denied), PublishError (Denied/Failed). Runtime converts at PUBLIC boundaries (Llm.Error.to_abi, Tool.Error.to_abi, {:denied,r} for every scope denial, {:failed,r} store/memory writes). LiveEffectError uncatchability FROZEN (spec §3.10 + STABILITY row). Store/memory runtime Denied is defense-in-depth only (compile gate makes it unreachable from Skein). e2e: structured_error_abi_test.exs incl. scenario-provider Err(LlmError.RateLimit(1500)) round trip.
- **C3 #298**: JsonSchema.validate/2 + decode/2 (recursive; uniqueItems/formats/oneOf/additionalProperties/nested; path-carrying violations; handles {:some,v}/:none + atom keys) shared by req.json[T], llm.json[T] (violations → Err(LlmError.InvalidSchema)), tool input AND output (output violations → ValidationError with "output:" prefix).
- **C4 #279**: llm.embed resolves PAST a model provider (resolve_embed_backend: replay → policy-enforced configured backend) — no embed provider form exists (LlmResponse text-only, spec §6.4). `given` KEPT per 2026-06-15 decision: seeding home for stateful fixtures (evaluated in order before expect, same scope, propagate boundary; store/memory scenario-local under test policy) — spec §3.10 rewritten (in-flux banner gone), c4_remainder_test.exs pins both.
- **C5 #255**: TYPED store tables — `capability store.table("games", Game)` (record type REQUIRED, exactly one @primary field; E0043 = first new code, registry synced in analyzer moduledoc + spec §7 + errors.md). Analyzer types get/put→Result[T,StoreError], delete→Result[PK,...], query→Result[List[T],...] + arg checks (store_call_type/store_arg_errors; store_tables(env) reads capability params [StringLit, Identifier]). Codegen threads SchemaGen JSON schema into every put (store_table_schema via scope __capabilities__+__type_decls__); Store.put/4 schema-checks via C3 (violation = {:failed,...}). Backing = schema-checked ETS (Ecto path stays dead). ~90 sites churned incl. spec §8 (BOTH copies), docs storage.md rewrite, dogfood corpus + upstream ports.
- **C6 #299**: EventStore.Persistence GenServer (supervised; enable(db) = start Repo + migrate + reload-into-ETS deduped + flag; async record casts; flush/0). append/1 writes through when enabled; `skein run` enables at <project>/.skein/events.db (--no-persist opts out; flag-spec parser gained {:flag, parsed} zero-value form). Persisted-shape contract pinned in Persistence moduledoc (JSON round trip: known keys re-atomized incl. stream; nil/bools no longer stringified). Shapes stay Pre-stable until Wave F.
- **#325**: SupervisorHost realizes __supervisors__/0 as real OTP Supervisors — agent-module resolution by CONVENTION (Skein.Agent.<ModShort>.<Target>; no __agents__ metadata; unresolvable → :child_skipped event, no crash); restart: brace-option honored (permanent default); every (re)start appends :supervisor/:child_started; Server.init boots them per mounted module; skein run mounts supervisor-only modules. Tests: kill→new pid + memory.kv survives; intensity exhaustion; one_for_all vs one_for_one.
- **#314**: B4 generator now covers guards (E0027-safe subset), typed interpolation, Float type, `?` propagation, memory/uuid effects, nested agents (linear phase chains), tools, handlers — 7 seeds green, no soundness bugs. **#315**: analyzer 6,458→5,091 lines; submodules Purity/Capabilities/AgentChecks/Warnings (verbatim moves; 11 @doc false seams on Skein.Analyzer: infer_type, types_compatible?, format_type, normalize_enum_refs, boundary_type_errors, location_from_meta, span_from_meta, capability_insertion_span, closest_name, strip_enum_prefix, handler_required_capability); left in main: type core, scenario envelopes, E0035/W0003. **AST.Assert is a real node now — the __assert__ dunder is GONE** (parser/analyzer/codegen/walkers; earlier MEMORY notes about __assert__ Call clauses are stale).
- Session gotchas: agents can't run mix concurrently with the main loop (serialize; delegate then WAIT); python regex block-deletion corrupted tool.ex once (git checkout restore + exact-anchor swaps only); `tool` is a RESERVED word — can't bind `Err(ToolError.ValidationError(tool, vs))`, use `t`; tool.call needs UpperIdent dotted tool names; tool blocks have NO capability section (module-level); rare "EXIT killed" flake on analyzer_interpolation_test (rerun); mix test 2>&1|tail exit code is tail's.
- **/release-readiness 0.5.0 ran (137 agents): NO_GO — all mechanical gates + toolchain e2e + dogfood green; blockers were the unstaged version bump (owner-gated, expected) + 10 confirmed CONTENT blockers + 40 warnings, all docs/examples that denied this release's own deliverables.** All 9 fixable blockers + the warning sweep were fixed on the same branch (commit `[docs] ...release-readiness...`): skein_assistant route → `POST "/ask/:session_id"` (req.params only carries PATH params — reading a non-declared param 500s); README RefundAgent wrapped in `module Refunds { type Ticket ... }` (agents can NOT declare `type` — nesting is the only way, and post-C5 the store capability's record type must exist; llm.chat needs a String arg → `ticket.details`); runtime/agents.md query example (stop()-terminated agents are :noproc — query live/suspended agents, terminated ones via EventStore.query(kind: :user_event)); capabilities-and-effects HTTP contract → Result[HttpResponse, HttpError]; site stability EventStore row + added structured-error-ABI row; site+canonical roadmap/CLAUDE/CONTRIBUTING/STABILITY/README/ARCHITECTURE re-baselined to "Wave C+D landed 2026-07-02"; spec §2.6 gained the five escape sequences (\n \t \\ \" \$ — anything else is two literal chars) and §3.2 cap_kind gained uuid|instant + optional parens; hello_http /echo now echoes req.body and /classify has real Int.parse logic; agent-primer NotFound bullet corrected (Err(StoreError.NotFound) DOES match) — same fix applied to FablePool-skein/AGENTS.md (the CLI template was already clean); v1.1 "content-addressed store #255" refs re-pointed (needs a fresh issue — #255 was consumed by C5). Compiler/runtime docs-site pages swept by two subagents (codegen scoped-label threading + put schema arg, lexer identifier classes, parser Wildcard/interpolation-AST, pipeline pass count + uuid/instant, getting-started, storage.md, agent-quick-reference, language/agents supervisor claim, runtime overview module list, property-test inventory, distribution subcommands, vscode build steps, syntax module-name regex).
- **GOTCHA discovered: pre-reset tags v1.0.0-rc.2/rc.3/rc.4 already exist on origin (June 12–13)** — the "v1.0.0-rc.2 — True release candidate" milestone name collides with an existing tag; the Wave F release will need rc.5 or a milestone rename. Flag to owner before the RC cut.
- **Release staged (owner approved 2026-07-02): mix.exs both → 0.5.0, dated CHANGELOG section, banners; preflight PASSED for v0.5.0; all on PR #330** — a green squash-merge auto-tags v0.5.0 and closes the 10 milestone issues. Final umbrella: 2,543 tests + 210 properties, 0 failures (one analyzer_interpolation "EXIT killed" flake seen, passes on rerun — known). **Merged + released 2026-07-02** (owner enabled auto-merge; tag v0.5.0 cut). Post-merge follow-ups landed on PR #331: milestones.json closes v0.4.0 + v0.5.0 (both were still "open" — the sync would have REOPENED them) and CLAUDE.md narrative synced. **Dogfood external half ARMED: owner added the `DOGFOOD_GITHUB_TOKEN` Actions secret 2026-07-02** (a briefly-added GH_PROJECTS_TOKEN fallback in ci.yml was reverted the same day — the session-env GH_PROJECTS_TOKEN is NOT an Actions secret, and that PAT can't administer repo secrets: 403 on the secrets API, though it DOES have read on both private ports). Pins did NOT need bumping: both port PRs were true merges (not squashes) — skein-testing#36 into its prelaunch branch, FablePool#5 into main — so the pinned revs stay reachable. Still open for owner: rc.5-vs-rename for the Wave F gate (rc.2–rc.4 tags already exist).

## Project State (v0.4.0 RELEASED — 2026-07-02 session, final)
- **v0.4.0 tagged via PR #328 merge** (de0f88b — release.yml auto-tags on green version-bump merges; owner pre-authorized the cut). Milestone **v0.4.0 — Truth & Soundness: zero open issues** (#313 via #326; #301/#319/#268/#318/#272 via sweep PR #327; #271 closed after CI soak). mix.exs 1.0.0-rc.4 → 0.4.0 (deliberate downward renumber; CHANGELOG explains).
- **`/release-readiness 0.4.0` verdict was NO_GO first** (141 agents / 68 units): all mechanical gates green, but **17 CONFIRMED content blockers** — docs pages the Wave B/close-out work had made false. All fixed on PR #328 before merge; every touched Skein snippet extracted verbatim + compile-verified. Blocker classes: (1) non-compiling published examples (README RefundAgent/at-a-glance/tool-policy; capabilities page ×6; tools.md; syntax.md RefundBot reading never-populated agent state — runtime inits state %{}; start params are NEVER copied in; the durable pattern is memory.put in start + memory.get(...)! in phases); (2) E0021/E0024 documented as warnings — both are ERRORS; (3) dead paths sold as live (Ecto store, SQLite EventStore) — honest ETS-only language now, C5/#255 + C6/#299 own the wiring; (4) superseded plan text (site roadmap What's-Next); (5) ARCHITECTURE §2.6/§4 fiction (Ecto wrapper; OTP-release packaging that doesn't exist).
- **One REAL compiler bug found by the sweep: `emit` outside an agent crashed codegen** (FunctionClauseError) while spec §6.7 said "events are always allowed". Fixed as **E0039** (agent-only walk in check_agent_only_calls, now also covering tool `implement` bodies); spec §6.7 scoped to agents (+§3 grammar note, §7 row), registry synced in all THREE copies; fixtures emit_outside_agent.skein + emit_in_tool_implement.skein. **No free E-codes remain below E0043.**
- Accepted residual sweep warnings (v0.5.0 docs chores, none behavioral): spec §2.6 escape sequences, timer.cancel spec-vs-analyzer drift (C1/#296), CLAUDE.md tree staleness, compiler-page internals (parser segments, codegen uuid/instant rows, lexer charset, pipeline uuid/instant), getting-started what-works omissions, property-test inventory, examples/README coverage note. Listed on PR #328 comment.
- Post-release totals: 2,403 tests + 210 properties, 0 failures. Gotchas this phase: parallel doc-agents running `mix skein.compile` during a root `mix test` → transient _build protocol-consolidation failure (rerun serially); Bash cwd resets to scratchpad after worker restarts (`cd /home/user/Skein` religiously); GitHub job-log MCP results overflow → grep the saved tool-result file.
- **NEXT SESSION: v0.5.0 — Runtime Contract & Dogfood** (do NOT start without owner direction): C1 effect-ABI registry #296, C2 structured-error ABI #297, C3 schema validation #298, C5 typed store #255, C6 EventStore persistence #299, #325 supervisor wiring, Wave D dogfood gate #262 (top priority per audit — both external ports are known-broken vs main), #279 narrowed (llm.embed provider + `given` grammar), #314 widen B4 generator, #315 analyzer factoring.

## Project State (v0.4.0 close-out sweep — 2026-07-02 session, cont.)
- **Owner mid-session directives**: abandon one-PR-per-issue — close the milestone in ONE sweep PR; explicit permission granted to cut the v0.4.0 tag (bump-version skill; mix.exs 1.0.0-rc.4 → 0.4.0).
- **Sweep branch commits (one per issue, `Closes` lines in the PR body)**: #301 resume de-reserved (lexer @keywords, spec §2.3 note + §6.8 rewrite, LSP semantic-tokens/completions dropped, positive fixture resume_identifier.skein); #319 policy cut (the parser NEVER had a policy clause — issue premise stale, it was already an unparseable generic error; removed ToolDecl.policy field + parser plumbing + targeted E0001 + spec §3.8 note; supervisor surface pinned as frozen contract in spec §3.9, wiring=#325 v0.5.0; ROADMAP #319 line + #325 under Wave C); #268 pre-paren `method!(args)`/`method?(args)` DELETED (targeted E0001 naming the postfix spelling; postfix !/? now CONTINUE the postfix chain via parse_unwrap_suffix loop — `get(id)!.name` works, which the old desugar provided; get!/put! purged from analyzer tables/codegen guards/LSP; Store.get!/put! + Memory.get! deleted with their direct tests; spec §6 signatures collapsed; repo-wide sed sweep of Skein sources — CAREFUL: the sweep also rewrote my own new negative fixture + parser tests that intentionally contain the removed form; restore them after any such sweep); #318 spec §3.12 "Expression Termination" (continuations: `.` `|>` binary ops both sides; terminations: line-initial `(` `[` `!` `?` never continue — the `!` case was a SILENT MISPARSE: `let x = a`↵`!b` stole the ! as postfix unwrap since prefix-not is also `!`; mechanism: parse/2 registers line-initial token positions in pdict `:skein_parser_line_initial`, O(1) lookups; parser_termination_test.exs pins all rules); Wave A stragglers (EventStore moduledoc/docs/STABILITY honesty — in-memory only, #299 owns wiring; CONTRIBUTING drops retired v0.6.0; #272 de-flaked: deterministic schedule tests pin crons to the SIMULATED past date `* 12 10 6 *` so no wall-clock tick can ever match — the flake class was `* * * * *` matching any stray real tick; #271 closed after green-CI soak).
- **#326/#313 merged first** (before the sweep directive): placeholder fix_code → nil. CI flake seen there: BedrockBackendTest stub-server `:eaddrinuse` port collision — re-kick with empty commit; not Topic (#271 evidence unaffected).
- Env: force-push denied BUT squash-merge + branch auto-delete means plain push recreates the branch cleanly after `checkout -B` onto origin/main. GitHub job logs via get_job_logs overflow — grep the saved tool-result file. Umbrella after sweep: compiler 1,434+94 / runtime 731+115 (get! tests deleted) / LSP 60 / CLI 176+1.

## Project State (v0.4.0 close-out — 2026-07-02 session)
- **Milestone push to finish v0.4.0** on branch `claude/skein-v0.4.0-truth-soundness-xaz3og` (one issue per PR; after each merge `git fetch origin main && git checkout -B <branch> origin/main`, plain push — force-push denied).
- **Post-audit residue already merged before this session**: #309 (bare Ok/Err), #310 (interpolation typing), #311 (newline-`(` parse fix, PR #323 — a `(` starting a new line never continues a call chain), #312 (E0028/E0029 registry rows, PR #324). Remaining open in milestone: #313, #301, #319, #268, #318, #272, #271 (close after green-CI soak).
- **Owner decisions locked 2026-07-02** (issue comments are the record): #301 → A (de-reserve `resume`); #319 rescoped — tool `policy` blocks CUT, `supervisor` STAYS (wired in v0.5.0 via #325; v0.4.0 only pins the declaration surface in spec §3.9 as the frozen contract; docs keep "metadata only" until #325 lands); #268 sharpened to OUTRIGHT deletion (`get!`/`put!` stop lexing, no deprecation, `get(k)!` is the one spelling); #300 resolved as Alternative B (no v0.6.0; substrate items in v1.1).
- **#313 (this PR)**: the E0020 enrichment (`enrich_fix_code`/`extract_type_mismatch_fix`) is DELETED and all 12 other `"// ..."` placeholder fix_code sites are nil now — fix_code contract is: applicable Skein or a template, else nil (guidance in fix_hint); spec §7 + analyzer_fix_code_test moduledoc document the nullable contract. error_span_test + analyzer_fix_code_test sweeps now REJECT any fix_code matching `\A\s*//`. The string-concat `+` keeps its real `"${a}${b}"` snippet. Gotcha: the enrichment pass only ran when source_lines were threaded — `Analyzer.analyze(ast)` directly (most tests) never saw it; test the enrichment path via `Compiler.compile_string`.
- Milestone exit plan: when zero open issues — update MEMORY, full umbrella + `/release-readiness 0.4.0`, then ASK owner about the 0.4.0 tag (mix.exs still 1.0.0-rc.4; bump is owner's call via bump-version skill). Do NOT start v0.5.0.
- Env notes this session: deps needed `mix deps.get` at umbrella root (exqlite compiled from source); `mise` shims required in every shell; #272 (ScheduleAutoFireTest "fires again in the next matching minute" refute_receive flake) reproduced once in a full run, passed on rerun — it is in-milestone to fix.

## Project State (post-Wave-B sanity check — 2026-07-02 audit session)
- **Audit-only session** (no code fixes): report at `docs/audits/2026-07-post-wave-b-sanity-check.md`; ROADMAP + milestones.json + scenario-env design-doc status re-baselined; #279 re-scope comment posted. Baseline at main=822c2be: **2,363 tests + 209 properties, 0 failures, 64s wall** (compiler 1,390+93 / runtime 737+115 / LSP 60 / CLI 176+1).
- **Wave B verified complete** — adversarial probes could NOT break the analyzer-accept ⇒ BEAM-load bridge (handler/agent/tool bodies, recursion, cross-enum, widened arms all reject correctly with E0010/E0020/E0023/E0037). B6 DID land provider contract checking + transitive purity — #279's "NOT landed" list was stale (narrow to llm.embed provider + `given` grammar; recommend P0→P1).
- **New issues filed**: #309 bare `Ok`/`Err` as a value compiles silently to an atom (analyzer.ex:2205 exemption); #310 interpolation segments unchecked — `"${fn_ref}"`/`"${record}"` compile then crash `{:unsupported_interpolation, v}` (codegen whitelist binary/int/float/atom, core_erlang.ex:2810); #311 newline-`(` juxtaposition (parser.ex:2283, newline-blind) — decide grammar pre-freeze; #312 spec §7 + errors.md missing E0028/E0029 rows; #313 E0020 fallback fix_code is `"// Fix the type mismatch"` (analyzer.ex:657-661, not Skein syntax); #314 widen B4 property generator; #315 analyzer factoring (registries out with C1, pass submodules, AST.Assert).
- **Wave C premises all re-verified live**: timer.cancel 3-way drift (analyzer.ex:162 / timer.ex:180 / spec:802 — `timer.cancel(ref)!` compiles+loads); `Err(LlmError.RateLimit(d))` arm compiles but can never match (C2); llm.json atomize-only (llm.ex:391); no Repo in supervision tree; EventStore durability moduledoc still false.
- **Dogfood urgency up**: ambient `Uuid.new()` is REMOVED from stdlib (analyzer.ex:349) → skein-testing (main.skein:114) and FablePool (fablepool.skein:991) are known-broken vs main; CI umbrella-only. #262 harness is the top v0.5.0 item.
- Recommended decisions: #300 → B (drop FablePool-capable 1.0 promise, no v0.6.0); #301 → A (de-reserve resume); close #271 after green-CI soak (fix 45c2d08 is on main).
- Stale-claim cleanup: AUDIT_FIRST_PRINCIPLES replay/spec-examples/instance-memory findings are stale (replay+golden e2e real); no erl_crash.dump exists; README error-code posture already corrected.
- Audit-session gotchas: Bash safety classifier outage → work read-only (Grep/Read/GitHub MCP) and batch probes for later; `list_issues` responses overflow — use perPage≤10 + minimal_output; Bash cwd persists across calls (a `cd apps/skein_compiler` made a later root `mix test` run compiler-only — re-check `pwd`).

## Project State (v0.4.0 Wave B: B4 — 2026-07-02 session, cont.)
- **B4/#293 implemented** (this PR): the soundness bridge "analyzer-accept ⇒ Core gen ⇒ BEAM compile ⇒ load" is now enforced. Probing found FOUR accepted-but-unbound-var producers, all fixed as structured errors at the site: unknown `&fn` refs (E0010, was silent :unknown in EVERY body kind — fn/handler/agent/test/provider/spawn-arg), unknown bare calls off the boundary path (E0010 — B2's E0037 only caught boundary crossings), bare fn name as a value (E0020, fix_code "&name"), unknown store-TABLE methods (E0010 — the guarded `when method in @store_methods` clause fell through to the silent Call catch-all). Also: calling a fn-typed VARIABLE (`let g = &f; g()`) is legal+codegen-supported — now typed with arity/arg checking (variable_call_result); calling a non-fn variable = E0020; `__assert__` (assert desugars to it, starts with `_` so lowercase guards MISS it) needs its own Call clause; deep field-access call targets = E0020 "cannot be called".
- **Nested-agent env gap exposed**: agents may call module-level fns (inherited as locals, skein-testing#8) but build_nested_agent_env never merged module_env.functions — silent :unknown had hidden it; now merged (agent's own win).
- **Codegen fallbacks are now raises**: the three unbound-var fallbacks (Identifier nil-scope, FnRef nil-arity, uppercase Module.field c_var) raise codegen_invariant_error (compiler-bug crash with node meta) — full suite green proves they're unreachable for accepted programs.
- **Property gate**: codegen_soundness_property_test.exs — StreamData generator over well-typed random modules (Int/String/Bool fns, let chains, match, cross-fn calls w/ typed args, fixed feature block: record+Option+Result+!+&fn callbacks); asserts compile_string → {:module}, load, and runs mod.unwrapped(). Generator gotcha found by the gate itself: **a line starting with `(` parses as a CALL of the previous expression** (juxtaposition — `let x = "s"` newline `(1+2)` = `"s"(1+2)`); generator keeps top-level operator left operands atomic. This parser wart is user-facing (now a structured E0020 "cannot be called", pre-B4 it was an unbound-var E0001) — possible future parser fix, out of B4 scope.
- **Positive corpus**: conformance/positive/*.skein + positive_corpus_test.exs (compile_file → load → call main/0 if exported; auto-test per fixture like the negative runner). 6 fixtures: records+Option, Result+?/!, callbacks+pipes+variable-call, tool service, agent lifecycle (module fn from phase handler), scenario providers. Remember: NO call expressions in string interpolation (E0002) — bind to lets first.
- New negative fixtures: fn_ref_unknown, unknown_bare_call, bare_fn_reference, store_unknown_method, variable_call_not_fn. Updated expectations: analyzer_test "! on unresolved call" + analyzer_boundary_test now expect E0010 AND E0037 (site error + boundary guard both fire; fn_return_unknown_boundary.skein fixture unchanged — E0037 still present).
- Spec §4.3 rule 14 (site-errors + the bridge invariant); §7 E0010/E0020 rows extended; errors.md; analyzer moduledoc.
- **Wave B COMPLETE when this merges** (B1–B6 all landed). Next: Wave A — #301 resume de-reserve (default A), spec §7 E0028/E0029 registry rows (registry jumps E0027→E0030), #268 bang-position sweep + get!/put! removal, #262 dogfood gate wiring.

## Project State (v0.4.0 Wave B: B6 — 2026-07-01 session, cont.)
- **B6/#295 implemented** (this PR): tool `implement` bodies checked against `Result[output, error]` — `check_tool_implement_inference` now uses the inferred body type (coarse check: `types_compatible?(body_type, {:result, :unknown, :unknown})`, E0020 "must return Result") and sets env key `tool_output: %{tool, fields}` (via Map.put, envs use extra keys like own_capabilities) so the Ok-constructor clause in infer_type shape-checks every `Ok(MapLit)` in the body against the `output { ... }` fields (unknown/missing-required/per-field mismatch, present Option = bare inner, mirroring RecordLit B5 rules; re-inference of field values DISCARDS errors — already reported by MapLit inference). Err half stays :dynamic seam (C2/#297). Runtime ABI truth: `tool.ex execute_tool` matches `impl.(input)` against {:ok,_}/{:error,_} — a bare body was a CaseClauseError at call time.
- **Provider contracts (NEW E0038)**: `@provider_contracts` table (uuid → `implement() -> Uuid`, instant → Instant, http.out → `(HttpRequest) -> Result[HttpResponse, HttpError]`, model → `(LlmRequest) -> Result[LlmResponse, LlmError]`; resolved-type comparison is EXACT equality). Pass 2h `check_provider_contracts` walks scenario envelope trees; wrong signature = E0038 with canonical signature in fix_code; implement under any OTHER kind = E0038 "does not support" (runtime resolves providers ONLY at http.ex/llm provider_backend/nondeterminism.ex — anything else is silently dead). Provider bodies now get full infer_type (params in scope) + declared-return check (E0020 "Provider return type mismatch") + #291 boundary guard — mirrors check_function.
- **Transitive purity**: `collect_effect_sites/3` (fns map name→body, visited MapSet for recursion) follows local fn calls AND `&fn` refs; sites are `{label, meta, via}` — meta stays the OUTERMOST call site in the pure context, via accumulates the chain ("reached via a -> b" appended to E0029 messages). New walker clauses: FieldAccess subject, StringLit interpolation segments ({:interpolation, expr} — but note expression interpolation is a PARSE error E0002, only ident/dot-access allowed, so effects can't actually hide there). `assert` parses as Call to `__assert__` — args walk covers it.
- **Fixture churn (~17 tests)**: stale bare-value tool bodies (`implement { "ok" }` / `{ 42 }` / bare maps) updated to `Ok({ ... })` across tool_test.exs, core_erlang_test.exs, analyzer_test.exs, pure_context_test.exs, scenario_envelope_test.exs + effect_in_provider_block.skein / scenario_envelope_incomplete.skein (kept single-purpose; watch `id: Uuid` vs `"static"` — :string is NOT compatible with :uuid). parser_test.exs bodies untouched (parser tests don't run the analyzer). New fixtures: tool_implement_not_result, tool_implement_output_shape_mismatch, provider_contract_mismatch, provider_unsupported_capability, transitive_effect_in_test, transitive_effect_in_provider. New test file: analyzer_contract_test.exs (24 tests).
- Spec: §4.3 rules 12 (tool Result contract) + 13 (provider contracts + transitive purity); §3.10 provider-contract paragraph; §7 E0020 row extended + E0038 row added (E0028/E0029 rows still MISSING — Wave A item). docs/site errors.md + language/tools.md (implement-must-return-Result note, stale examples fixed). E0039 is the only free code now.
- Umbrella after B6: compiler 1,363+92, runtime 737+115, LSP 60, CLI 176+1 = 2,336 tests + 208 properties.
- **Wave B remaining**: B4/#293 (analyzer-success ⇒ BEAM-load property gate; remove core_erlang.ex unbound-var fallbacks: Identifier fallthrough `nil -> :cerl.c_var(var_name(name))` + FnRef nil clause). Then Wave A: #301 resume de-reserve (default A), spec §7 E0028/E0029 rows, #268 bang-position sweep + get!/put! removal, #262 dogfood gate.

## Project State (v0.4.0 Wave B: B5 — 2026-07-01 session, cont.)
- **B5/#294 implemented** (this PR): records are NOMINAL — both `map ~ user_type` wildcard clauses removed from `types_compatible?`; `TypeName { ... }` (RecordLit, landed post-audit for #274/#279) is the one construction form. Bare unparameterized `Map` TypeRef (HttpResponse.body builtin) now resolves `{:map, :dynamic, :dynamic}` — clause must sit BEFORE the generic `params: []` resolve_type clause or it's shadowed.
- **Option totality**: RecordLit present Option[T] fields take the BARE inner value (presence⇒Some, like JSON decode; an already-Option value is E0020 — no Some() constructor exists so accepting both would make the codegen wrap ambiguous). Analyzer Pass 0b (`annotate_record_literals`, after named-args Pass 0a in BOTH Module and Agent analyze overloads) fills new `AST.RecordLit.some_fields`/`none_fields`; codegen wraps `{:some, v}` and injects `:none` — no context threading needed (analyzer-rewrites-AST pattern, like named args).
- **Runtime uniformity**: new `Skein.Runtime.Options.strip/1` (deep: {:some,v}→v, :none map keys omitted, structs pass through) wired into handler.ex encode_json, http.ex request bodies, router.ex trace export. `JsonSchema.atomize` now atom-key aware (fetch_property tries string form; already-tagged values pass through coerce_field) so `tool.ex execute_tool` coerces output via `schema[:output_schema]`. `EctoSchema.build_schema` emits `__skein_option_fields__/0`; `StoreEcto` put unwraps ({:some,v}→v, :none→nil) before cast and `schema_to_map` re-tags on every read (get/put-return/query).
- **MigrationGen bug found by round-trip test**: `unique_version` was `System.system_time(:second)` — two migrations in one second collided and Ecto.Migrator SILENTLY skipped the second (no table created, run_migration still :ok). Fixed: ms*1000 + unique_integer suffix. Symptom: order-dependent "no such table" in store_ecto_test.
- Spec: §3.11 grammar `record_lit` + nominal-construction paragraph; §4.3 rules 10 (nominal) + 11 (total Option, wire inversion). Tool `implement` `Ok({ ... })` outputs stay MAP literals (output block is an anonymous shape, not a named record) — spec §8.4 unchanged and compiles.
- New tests: analyzer_nominal_record_test.exs, integration/record_option_boundaries_test.exs (Handler.dispatch e2e strip + decode==construct equality via Skein `==`), store_ecto Option round-trip, runtime options_test.exs + tool output coercion tests. Fixtures: map_literal_as_record, record_optional_field_type_mismatch.

## Project State (v0.4.0 Wave B: B3 — 2026-07-01 session, cont.)
- **B3/#292 implemented** (this PR): local calls type-check every argument against declared params (E0020 naming the parameter); new `@effect_param_types` table (positional, aligned with `@effect_param_names`; payload slots `:dynamic` until C1) checked via `effect_call_type_errors` next to the arity check; `&fn` infers `{:fn, params, ret}` from `env.functions` (unresolved name stays `:unknown` → E0037 at boundary until B4); `types_compatible?` fn clause is contravariant in params / covariant in return, exact arity; stdlib higher-order slots upgraded to `{:fn, ...}` shapes (runtime-verified arities: all List callbacks /1 except reduce /2 (acc, elem); Map.filter /2 (k, v); filter/find/any/all/none/count callbacks return `:bool`); `stdlib_return_type/4` derives List.map → `{:list, cb_ret}` and List.reduce → cb_ret else init type. Named args already desugar to positional pre-inference, so they route through the same checks for free.
- **B3 ripple**: the `&base`-returned-as-Int case moved from E0037 to a concrete E0020 (`fn() -> Int` vs `Int`) — fn_return_unknown_boundary.skein fixture + analyzer_boundary_test now use an unresolved bare call (`mystery()!`) as the remaining :unknown producer. New fixtures: local_call_arg_type_mismatch, effect_arg_type_mismatch, callback_arity_mismatch, callback_return_type_mismatch. New test file: analyzer_call_typing_test.exs (22 tests). Spec §4.3 rule 9 + §7 E0020 row + errors.md + analyzer moduledoc updated.
- process.spawn/timer work bodies are ZERO-arg callables (`is_function(fun, 0)` in runtime); llm.stream on_chunk is `{:fn, [:string], :dynamic}`.

## Project State (v0.4.0 Wave B: B2+B1 — 2026-07-01 session)
- **Milestone v0.4.0 — Truth & Soundness in progress** on the single designated branch `claude/skein-v0.4.0-truth-soundness-gynztp` (one issue per PR; after each merge, `git checkout -B <branch> origin/main` — the merge commit contains the branch tip, so a PLAIN push fast-forwards; force-push gets denied by the permission classifier).
- **B2/#291 MERGED (PR #303)**: `types_compatible?` is now DIRECTIONAL `(actual, expected)` at every call site. `Json` accepts anything inbound, never outbound without decode. New lattice members: `:dynamic` (spec-sanctioned dynamic seams — untyped store/memory/tool payloads, tool-error `.from`, gen_statem `state`, handler req params; MAY cross declared boundaries until C1/C3/C5) vs `:unknown` (inference failure; boundary-rejected). New **E0037** fires in `check_function` when the inferred return is top-level `:unknown` or contains `{:widened, a, b}` (unify_or_unknown now records incompatible widenings instead of erasing). `@effect_return_types`/`@store_return_types`/stdlib-registry generics all use `:dynamic` now. `permissive_type?/1` helper gates operator noise.
- **B2 exposed + fixed**: match subjects now normalize ({:user_type, E} → {:enum, E}) BEFORE arm binding; dotted variant patterns parse as ONE identifier "Enum.Variant" — bind_pattern strips the enum prefix; new dead-arm E0020 when a variant pattern's arity ≠ declared fields (runtime value is a {tag, fields...} tuple → wrong-size tuple pattern NEVER matches). Spec §8.3's own example carried two such dead arms (`ChargeSucceeded(c)` binding a 2-field variant) — spec + spec_examples_test.exs BOTH fixed (test EMBEDS the §8 sources; keep in sync).
- **B1/#290 (PR #304)**: `?` on Err now truly early-returns. Codegen: Err branch throws `{:"$skein_propagate", {:error, e}}`; `wrap_propagate(ast, expr, mode)` installs a try/catch at every user-body boundary (generate_fn, generate_handler_fn, generate_tool_impl_fn, agent start/phase handlers, build_provider_closure, and test/scenario/golden). Non-marker throws/raises re-raise via erlang:raise/3 (idempotent-skip throw + AssertionError pass through). Bodies without `?` generate unchanged (`contains_propagate?` AST walk). **test/scenario/golden use mode :raise** — the CLI runner (skein_cli.ex execute_test) fails only on raises, so a returned Err would be a SILENT PASS; propagated Err raises `{:unhandled_propagated_err, e}`. Scenario wrapper encloses `given` lets (a `?` in a given value must not escape as uncaught throw). Analyzer: propagated err type checked vs enclosing Result error component (E0023 extended; `:dynamic` err components pass).
- Negative corpus grew: fn_return_unknown_boundary (E0037, &fn ref), json_downcast_boundary (E0020), match_widened_result_boundary (E0037), variant_pattern_arity_mismatch (E0020), propagate_error_type_mismatch (E0023). New test files: analyzer_boundary_test.exs, integration/propagate_test.exs.
- **Wave B remaining**: B3/#292 (arg typing + `{:fn, params, ret}` callable type — stdlib registry `:dynamic` params are the slot to upgrade; List.reduce return could derive from init arg), B5/#294 (Option totality + nominal records — the `map ~ user_type` clauses at types_compatible? are B5's to remove; store_ecto.ex schema_to_map + tool.ex output need `:none`/`{:some,v}` coercion), B6/#295 (check_tool_implement_inference DISCARDS the inferred type — compare vs Result[Out,Err]; provider bodies get NO infer_type pass; purity non-transitive in collect_effect_sites), B4/#293 (property analyzer-success ⇒ BEAM load; then remove core_erlang.ex unbound-var fallbacks: Identifier fallthrough + FnRef nil-arity). Wave A: #301 resume de-reserve (default A), spec §7 E0028/E0029 rows missing (registry jumps E0027→E0030), #268 bang-position sweep + get!/put! removal.
- Env gotchas: `mise` shims needed (`eval "$(/root/.local/bin/mise activate bash --shims)"`); umbrella totals after B1: 2,252 tests + 208 properties (compiler 1,288+92, runtime 728+115, LSP 60, CLI 176+1). Runtime totals line can interleave with Exqlite log noise — grep "properties," not "tests,". E0038/E0039 still free.
- User design Q&A on record: `!`/`?` do NOT violate one-way-to-do-things — `match` can't early-return (no `return` construct), so `?` is the only early-exit; `!` the only crash-on-Err; per-intent single spelling. Kept, not cut (recommendation accepted implicitly).

## Project State (#234 + #150 — 2026-06-12 evening session)
- **PR #238** (branch claude/zen-sagan-yy1thh, one commit per issue) resolves the LAST two v1.0.0 Release milestone items: #234 (interpolation segments → AST nodes) and #150 (span + edit_kind machine-applicable fixes). GA milestone empty when it merges. v1.0.0-rc.2 released earlier same day (PR #235).
- **#234**: parser normalizes `{:interpolation, raw_token}` → `%AST.Identifier{}`/`%AST.FieldAccess{}` (normalize_string_segments in parser); generate_interpolation/2 DELETED (segments route through generate_expr → `${state.field}` now works in agent handlers via the __state_var__ clause); new scope-independent analyzer pass `check_interpolation_shapes` (module Pass 2c over declarations-sans-agents ++ test_views; agent Pass 5c over agent_decl_views) owns uppercase-root E0010 + interpolated-string-pattern E0020 — infer-path check_interpolation keeps ONLY the unknown-ident scope check (skips uppercase) so nothing double-reports. Raw-token crashes fixed: `"${}"` = lexer E0002; `${Foo}` in handler/test bodies = E0010 (was FunctionClauseError — handler/test bodies skip infer_type entirely); pattern interpolation = E0020 (was generate_pattern crash).
- **#150**: Skein.Error gains span (1-based, end-EXCLUSIVE col, nested maps for JSON) + edit_kind (:replace/:insert_before/:insert_after/:insert_line/:delete_line). edit_kind is the machine-applicability DISCRIMINATOR — nil means fix_code is a template ("fn name() -> Type { ... }", closest_name "name"/"TypeName" fallbacks). Skein.Error.Edit.apply_fix/2 = reference applier; error_span_test.exs sweeps invariants + REQUIRED applicable codes + apply-fix-resolves-error round trip. LSP: data carries string-keyed "span"/"edit_kind", generic path first, phase-1 per-code mapping kept as span-less fallback. MCP compile_check inherits fields via @derive Jason.Encoder (zero code).
- Gotchas learned: AST.Let meta points at `let` keyword → added name_meta field for W0001 spans; Call meta points at the LPAREN (not target) → stdlib/dotted suggestion fixes stay span-less (adjacency unknowable); unexpected_token_error with quoted "'{'" descriptions renders the SAME message as expect/3 (default_fix_code regex distinguishes literal→:insert_before vs template→nil); E0012 insertion point = capability_insertion_span(env) using own_capabilities last meta else new env decl_meta (build_initial_env/build_agent_env; nested agent env inherits via map-update).
- capability_param_fingerprint now strips segment meta (StringLit segments carry AST nodes post-#234 — structural dedup would otherwise break).
- Umbrella after both: 1,953 tests + 199 properties green (compiler 1,155 / runtime 588 / LSP 60 / CLI 150).

## Project State (rc.1 soak audit — 2026-06-12 overnight session)
- **v1.0.0-rc.1 TAGGED** (auto-tag on PR #222 merge, commit 9ae8677); GitHub Release Readiness workflow run #1 green on main. /release-readiness rc-soak pass: ALL gates green (1,908 tests + 199 properties 0 failures; preflight pass; scaffold e2e 2/2; 16/16 examples compile).
- Sweep: 19 auditors over 35 docs pages + 8 spec sections + 17 examples + 8 meta-docs; 6 NEW blockers each confirmed by 2 adversarial verifiers; ~24 warnings self-verified (subagent spend limit hit mid-verification — verify warnings directly when that happens).
- Filed #223–#229 (docs accuracy) into v1.0.0 Release milestone (number 6); addenda commented on #199/#200. Fixed EVERYTHING on branch claude/release-readiness-1-0-0-rc1-9bpl9p, one commit per issue: #196 (W0001 now walks raw interpolation tokens {:ident,...}/{:field_access,...} in collect_referenced_identifiers), #197 (float underscores = structured E0003 — E0003 is now EMITTED, only E0013 stays reserved; spec §7 + errors.md updated), #199 (+zero-warnings guard in examples_test; skein_assistant_test.exs needed alignment — dedicated per-example test files exist under test/skein/examples/!), #200, #223–#229.
- GA milestone after this PR merges: EMPTY → promote rc to v1.0.0 via /bump-version 1.0.0 once soaked.
- Spec banner now "Version 1.0 — June 2026"; milestones.json: v1.0.0-rc Release closed; nimble_parsec dep REMOVED from skein_compiler (was never used; lexer is hand-written).
- Gotcha: `mix test 2>&1 | tail` exit code is tail's, not mix's — use pipefail. Concurrent mix (skein.compile during mix test) can race protocol consolidation in _build ("could not write Elixir.Inspect.beam") — false example-compile failures; re-run serially.
- **Second /release-readiness wave (#205–#220, 16 issues) all fixed on PR #221** (branch claude/v1-rc-release-burndown-r1mqil, one commit per issue, Closes #NN each). Wave 1 (#182–#195, PR #203/#204) merged earlier same day.
- Code fixes: #205 ListLit codegen clause (was raw FunctionClauseError); #206 pipes — analyzer AND codegen now desugar `l |> call(args)` → `call(l, args)` (was: analyzer didn't thread, codegen emitted unbound var); #207 Schedule.dispatch_handler catches {:idempotent_skip} (escaping throw crashed the GenServer + dropped ALL registrations); #208 Map.get! REMOVED (option 2: lexer can't ever produce `get!` ident; doc Option.unwrap(Map.get(m,k), default)); #209 spec-side: interpolation is ${ident}/${ident.dot} only + new E0002 "Expressions are not allowed in string interpolation" when closing brace present on line; #220 skein.toml parser skips unknown keys/values/table forms everywhere, halts ONLY on known [llm] keys (backend/base_url/api_key_env/model_map/region) with bad values — STABILITY promise now true
- Spec: #216 tool.list/schema → Result[...]; #217 §6.11 timer/process → Result-wrapped; #218 ParseError→String (4 parse sigs)
- Docs: #210 agents.md rewritten — start params NEVER reach state (get_state = %{}), transition() can't carry state; ALL examples now memory.kv put-in-start/get!-in-phase, all compile-verified; events keyed :event not :type; nested-agent module is Skein.Agent.<Module>.<Agent>; #211 supervisors.md = declared semantics + __supervisors__/0 metadata only (nothing consumes it); #212 stdlib.md (Some() doesn't exist — Options come from stdlib returns; map literals are ATOM-keyed so Map.get("k") = None — use Map.put-built maps; Uuid types Uuid not String); #213 codegen.md 2-arg memory.put; #214 SchemaGen.to_json_schema (not generate), required sorted alphabetically; #215 'trace export' command doesn't exist — both STABILITY copies reworded; #219 ARCHITECTURE.md real tree (SkeinRuntime.Application → EtsTables/Process/Queue/Topic/Schedule/Timer), checkpointing claim deleted, real Memory/Tool APIs
- Verified-in-session facts: local fn calls check ARITY only, not arg types (stdlib calls DO check types); `m.name` on a map-literal let-binding does NOT compile ("Field access only on user-defined types"); ~s(...) sigil breaks on parens-in-string — use ~s|...|
- Next: PR #221 green → squash-merge → /bump-version 1.0.0-rc.1; GA milestone (#196 #197 #199 #200) follows

## Project State (v1.0.0-rc burndown — 2026-06-12 session)
- **Entire v1.0.0-rc Release milestone (#182–#195) fixed on PR #203** (branch claude/v1-rc-release-burndown-90hdqx, one commit per issue, Closes #NN in each) — rc tags when it merges green. Next: merge #203, bump to 1.0.0-rc.1 (/bump-version), rc soak while the **v1.0.0 Release** GA milestone (#196 W0001 interpolation, #197 float underscore lexer crash, #199 examples, #200 meta-docs) lands; #198 FIXED on PR #203 (mix aliases route through Main.dispatch — real output + exit codes; CLI.compile returns {:ok, mod, warnings})
- Filed **#202** (v1.1): docs/spec drift guard — CI compile-checks for docs code blocks, registry drift tests (error codes/keywords/stdlib), generated tables; ROADMAP links it
- Decisions locked this session: in-agent resume() does NOT exist (host-side Agent.resume/2, spec §6.8); llm.stream(model, system, input[, on_chunk]) with String chunks (§6.4, [T] removed); queue.publish wired (Queue.publish/3 via shared Capability.check_scoped); Instant.diff -> :duration; Option/Result.unwrap(x, default) non-raising 2-arity ONLY (raising = `!`); process.spawn named param is task:; float literals are deliberately NOT patterns (guard workaround documented §3.11)
- New error codes: **E0036** stop() outside agent; E0033 now ALSO fires for transition() outside agent (kept its no-Phase-enum-in-agent meaning); E0003/E0013 documented as reserved-never-emitted; spec §7 has a Severity column (E0021/E0031/E0042 are warnings, E0024 dual error/warning)
- **Effect-call arity checking (E0020)**: positional effect calls checked against @effect_param_names/@effect_optional_params bounds — in infer_type (module fns) AND a dedicated walk for agent handler bodies (check_handler_effect_arity + generic collect_calls walker), since handler bodies skip infer_type entirely. Docs examples with 3-arg memory.put compiled before this and crashed at runtime
- Docs verification trick: extract fenced ```skein blocks, write each to /tmp, run Skein.Compiler.check_file via `mix run --no-start` from apps/skein_compiler; full module/agent blocks must be clean, fragments/error-demos are exempt. The /tmp/check_blocks.exs harness pattern works well
- Docs conventions enforced this session: NO hard-coded test counts anywhere in docs (non-numeric prose only); canonical model id claude-opus-4-8 (claude-sonnet-4-20250514 retired 2026-06-15); internal links need the /Skein/ base; memory.* call sites never take the namespace (capability threads it)
- **Background-agent gotcha: session resume/compaction ORPHANS background agent task handles** (TaskOutput says "No task found") while their on-disk edits survive. Recovery: check `git status` for which files were edited, verify the orphaned work yourself (the agents may have died pre-verification), relaunch what's missing. Agent reports also arrive only via completion notifications — poke with TaskOutput block=false
- CI green on every push so far; PR body lists all Closes lines

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
