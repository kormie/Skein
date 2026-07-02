# Changelog

## v0.5.0 (2026-07-02)

**Runtime Contract & Dogfood.** The complete **v0.5.0 — Runtime Contract &
Dogfood** milestone: Wave C makes the runtime expose exactly the contract the
analyzer and spec claim (C1–C6), Wave D adds a continuous executable dogfood
gate, and `supervisor` declarations become real OTP supervision. The runtime
contract drift found by the 2026-06-19 audit is closed; the structured-error
ABI is the first frozen surface on the road to 1.0.

### Language & Compiler

- **One authoritative effect ABI (C1):** `Skein.EffectABI` is the single
  registry for every effect method signature, store method, scenario provider
  contract, and effect error enum. The analyzer's effect/store/provider tables
  and codegen's dispatch maps are derived from it, spec §6 signature lines are
  drift-tested in both directions, and a runtime ABI matrix pins every
  method's live success/failure shape with registry-enforced completeness —
  editing any copy alone fails CI. Contract fixes shipped by the registry:
  `timer.cancel` returns `Result[String, String]` (`Ok` = the ref, idempotent)
  and `event.log` returns `Result[String, String]` (`Ok` = the event name, so
  a scope denial is visible).
- **Typed store tables (C5):** `capability store.table("games", Game)` names a
  declared record type with exactly one `@primary` field (violations are the
  new **E0043**). Store methods are typed against it — `get`/`put` as
  `Result[Game, StoreError]`, `delete` as `Result[PK, StoreError]`, `query` as
  `Result[List[Game], StoreError]` — with records and keys argument-checked
  (E0020). Codegen threads the record's derived JSON Schema into every `put`
  and the runtime schema-checks each write (defense in depth behind the
  compile-time gate). **Breaking:** untyped `store.table("name")` declarations
  no longer compile.
- **Analyzer factoring (#315):** the contiguous pass groups are real
  submodules (`Purity`, `Capabilities`, `AgentChecks`, `Warnings`), the
  hand-maintained registries ride the C1 registry, and `assert` is a
  first-class `AST.Assert` node (the `__assert__` parser desugar — the one
  "no desugaring in the parser" violation — is gone).
- **Wider soundness property gate (#314):** the B4 analyzer-accept ⇒
  BEAM-load generator now also produces guarded match arms, typed string
  interpolation, `Float` arithmetic, `?`-propagating `Result` fns,
  capability-gated `memory`/`uuid` effects, nested agents with generated
  phase enums, tools with randomized I/O, and HTTP handlers.

### Runtime

- **One structured-error ABI (C2, frozen):** every effect error is matchable
  from Skein. The builtin error enums (`HttpError`, `LlmError`, `ToolError`,
  `StoreError`, `MemoryError`, `PublishError`, `NotFound`) are real enum
  declarations materialized from the C1 registry; variants lower to
  snake_case atoms/tuples and the runtime converts its internal error structs
  at every public boundary — `Err(LlmError.RateLimit(ms))`,
  `Err(ToolError.ValidationError(t, violations))`, and
  `Err(HttpError.Status(code, body))` arms really match. Store/memory write
  failures are structured (`Failed(reason)`/`Denied(reason)`), never bare
  strings. The variant registry is frozen (see `docs/STABILITY.md`), and the
  blocked-live `LiveEffectError` raise is documented and frozen as
  intentionally uncatchable.
- **One recursive schema engine (C3):** `req.json[T]`, `llm.json[T]`, and
  tool input **and output** all validate through the same recursive
  validator/decoder (`Skein.Runtime.JsonSchema`) — nested objects/arrays,
  `required`, `enum`, min/max, `uniqueItems`, string formats, `oneOf`,
  `additionalProperties`. `llm.json[T]` schema violations are
  `Err(LlmError.InvalidSchema(violations))`; a wrong-shaped tool
  implementation result is `Err(ToolError.ValidationError)` with
  `output:`-prefixed violations.
- **EventStore persistence (C6):** the SQLite backend is wired onto the
  ordinary append path. Opt-in via `Persistence.enable/1`; `skein run`
  enables it by default at `<project>/.skein/events.db` (`--no-persist` opts
  out) and reloads persisted history on restart (deduplicated). Restart
  durability is tested; persisted shapes stay Pre-stable until the Wave F
  freeze.
- **Real OTP supervision (#325):** `supervisor` declarations boot real
  supervisors under `skein run` (`Skein.Runtime.SupervisorHost`). Children
  resolve to compiled nested agents by convention, brace-block entries are
  `on start(...)` args with `restart:` selecting the OTP policy, declared
  strategy and `max_restarts` intensity are enforced, every (re)start appends
  a `:supervisor`/`:child_started` event, and `memory.kv` state survives
  restarts.
- **C4 remainder (#279):** `llm.embed` resolves past a scenario `model`
  provider to the deterministic backend (there is no embed provider form —
  `LlmResponse` is text-only, spec §6.4), and `given` is confirmed as the
  home for seeding stateful scenario fixtures with its evaluation
  order/scoping specified (§3.10).

### Testing & CI

- **Continuous dogfood gate (Wave D/#262):** both external dogfood ports
  (skein-testing's Dungeon, FablePool) were migrated to current Skein and
  pass against main. Checked-in reduced ports run inside every `mix test`
  with exact pinned test counts (`conformance/dogfood/`,
  `conformance/dogfood.json`), and a dedicated CI job additionally clones
  both upstream repos at machine-readable pins and executes their suites
  (external half armed by the `DOGFOOD_GITHUB_TOKEN` secret).
- Every complete-module ` ```skein ` fence in the docs site and spec now
  compiles in CI (`docs_fences_test.exs`), error-demo fences must emit their
  annotated codes, and the negative corpus asserts the complete diagnostic
  set per fixture plus the structured-diagnostic contract.

### Spec & Docs

- Spec §6 signatures are registry-pinned; §6 documents the frozen effect
  error enums; §3.10 specifies `given` and the frozen `LiveEffectError`
  decision; §3.9 documents live supervisor semantics; §3.2 documents typed
  `store.table` params and the full capability-kind list (including
  `uuid`/`instant`); §2.6 documents the five string escape sequences; §7
  gains the E0043 row.
- The docs site, README, ROADMAP, ARCHITECTURE, STABILITY, and CONTRIBUTING
  were release-readiness-swept: every page that described the pre-C1–C6
  contracts (string HTTP errors, unvalidated `llm.json`, unwired
  persistence, metadata-only supervisors, untyped store) now documents the
  landed behavior, and the broken canonical examples were fixed
  (`skein_assistant` route is `POST /ask/:session_id`; the README RefundAgent
  snippet genuinely compiles; `hello_http`'s `/echo` and `/classify` do what
  their comments say).

## v0.4.0 (2026-07-02)

**Truth & Soundness.** This release *renumbers downward on purpose*: the
2026-06-15/19 audits found the rc line was tagged prematurely (analyzer/
codegen soundness was not established; runtime contracts had drifted), so
the release train was reset to development releases — v0.4.0, then v0.5.0
(Runtime Contract & Dogfood), then a true v1.0.0-rc.2. v0.4.0 packages the
complete **v0.4.0 — Truth & Soundness** milestone: the Wave A truth reset,
the full Wave B analyzer/codegen soundness program (B1–B6, adversarially
audit-verified), its residue, and the pre-freeze surface cuts.

### Language & Compiler

- **Soundness (Wave B, B1–B6):** `?` truly early-returns from every user
  body with the propagated error type checked (E0023); internal
  `:unknown`/widened types can no longer cross declared boundaries
  (new E0037) and `Json` no longer downcasts silently; call arguments are
  type-checked for local, effect, and callback calls in every body kind,
  with a real `{:fn, params, ret}` callable type for `&fn` references;
  analyzer acceptance now guarantees Core Erlang generation, BEAM
  compilation, and load (unknown references are site errors in every body
  kind; codegen's unbound-variable fallbacks became compiler-bug
  invariants; a StreamData property gate plus a positive conformance
  corpus pin the bridge); records are nominal (`TypeName { ... }` is the
  one construction form) with total `Option` handling across
  construction, JSON, store, and tool boundaries; tool `implement` bodies
  are checked against `Result[output, error]` field-by-field, scenario
  provider bodies against exact per-capability contracts (new E0038), and
  purity checking is transitive through local calls and `&fn` references
  (E0029 reports the call chain).
- **Effect honesty:** effect calls are typed as `Result`, so a missing
  `!`/`?` is a compile error instead of a runtime crash; `String +
  String` is a compile error (build strings with interpolation);
  `uuid.new()` / `instant.now()` are capability-gated effects — ambient
  `Uuid.new()` is gone; non-exhaustive matches on closed types are
  errors; the type lattice is invariant (#259). **Breaking:**
  `List.reduce` now calls its callback as `f(acc, element)`, matching
  spec §5.4 (it previously passed the arguments reversed). `emit` is
  agent-only (new E0039) — module code records events with `event.log`.
- **Interpolation is typed:** `${...}` renders exactly the canonical
  scalars (`String`, `Int`, `Float`, `Bool`, `Uuid`, `Instant`); records,
  fn references, `Option`/`Result`, enums, and `Duration` are compile
  errors with conversion hints instead of runtime
  `:unsupported_interpolation` crashes. Bare `Ok`/`Err` used as a value
  is rejected instead of silently lowering to an atom.
- **Expression termination is specified (new spec §3.12):** field access,
  `|>`, and binary operators continue across newlines on either side; a
  line-initial call `(`, type-argument `[`, and postfix `!`/`?` never
  continue the previous expression (a line-initial `!` used to be
  silently stolen as an unwrap — prefix not is also `!`). Parser property
  tests pin every rule.
- **Surface cuts (pre-freeze, breaking):** the pre-paren unwrap spellings
  `method!(args)` / `method?(args)` were deleted — `get(k)!` is the one
  spelling, postfix `!`/`?` now continue the postfix chain
  (`get(id)!.name`), and the vestigial `get!`/`put!` methods are gone
  from the registries, runtime, and spec; tool `policy` blocks were cut
  from the grammar (parsing one is a targeted error); `resume` is
  de-reserved and usable as an ordinary identifier (agents remain resumed
  host-side via `Agent.resume/2`). `supervisor` stays: its declaration
  contract is pinned in spec §3.9 as the frozen surface, with runtime
  wiring tracked for v0.5.0 (#325).
- **Agent-writability:** `fix_code` is never a prose placeholder — it is
  applicable Skein or `nil` (guidance lives in `fix_hint`); the E0028/
  E0029 registry rows exist in spec §7 and the docs site; a newline-`(`
  no longer parses as a call of the previous expression (#311).

### Runtime

- **Scenario-scoped capability environments are real:** a dynamic
  capability-context stack resolves every effect
  (`implement → replay → test-default → live`), scenario `implement`
  providers compile into capability envelopes, spawned work inherits the
  scenario context, and blocked live effects raise a deliberate
  `LiveEffectError`. The old `Dependencies`/`with_overrides` override
  plane is retired.
- **Deterministic test runner:** `skein test` runs every
  `scenario`/`golden` under a conservative effect policy (no accidental
  network; `--allow-live` opts in), with scenario-local state isolation;
  golden bodies genuinely replay recorded traces.
- HTTP non-2xx responses are `Err(Status(code, body))` per spec §6.1;
  store/memory misses return `Err(NotFound)`-matchable results;
  `req.json[T]` enforces `@`-constraints and coerces `Option` fields.
- EventStore durability language is honest: the log is in-memory only
  (the SQLite backend is not wired into the append path — #299 tracks
  persistence), and the docs/STABILITY classification says so.

### CLI

- Versioned `--json` output for `compile`/`build`/`test`/`trace` — the
  stable agent contract for driving Skein from tooling (#284) — plus a
  framework-neutral `skein trace` renderer (and a crash fix).

### Testing

- The negative conformance corpus (pinned diagnostics per fixture) and a
  positive corpus (compile → load → run) gate the GA invariants; the
  suite grew to ~2,400 tests + 210 properties. Schedule auto-fire tests
  are immune to wall-clock ticks (crons pinned to a simulated past date)
  and the Topic state-leak flake is fixed.

### Spec & Docs

- Truthful pre-1.0 posture everywhere: the spec banner, README,
  CONTRIBUTING, STABILITY, and the roadmap all state that GA is not
  imminent and nothing is frozen yet; the roadmap is re-planned around
  contract-first waves (A–F) with v0.4.0/v0.5.0 development milestones
  (the conditional canonical-substrate milestone was retired — #300
  resolved as Alternative B).
- New: first-principles P4 ("all nondeterminism is controlled"), the
  scenario-capability-environments design doc, the post-Wave-B sanity
  check audit (`docs/audits/`), spec §3.12, and the pinned supervisor
  declaration contract (§3.9).

## v1.0.0-rc.4 (2026-06-14)

Completing two rc.3 findings that shipped only partially (the
v1.0.0-rc.4 milestone on the *Skein Post MVP Tracker*).

### Runtime

- `req.json[T]` and `llm.json[T]` now coerce **nested** object-typed
  fields recursively, not just top-level keys. A declared nested record
  field (e.g. `body.address.city`) previously came back as a string-keyed
  map and crashed with a `KeyError` on the atom field; the JSON Schema
  derived from `T` now inlines nested record/enum types, so the shared
  `Skein.Runtime.JsonSchema` atomizer descends into them and the test LLM
  backend shapes nested fields too (skein-testing#2, #30).
- `store.<table>.query(filter)` returns `Err(StoreError)` for an unknown
  filter field instead of silently returning `Ok([])`, so typos and bad
  column names fail loudly through `!`/`?` rather than masquerading as "no
  results". Valid filters are unchanged (skein-testing#24).

## v1.0.0-rc.3 (2026-06-13)

The **third 1.0 release candidate** — burning down the tractable runtime,
correctness, and agent-writability findings from exercising rc.2 (the
*Skein Post MVP Tracker*; reports filed in `kormie/skein-testing`). The
deeper language-design items surfaced (effect Result typing, matchable
`Err(NotFound)`/`HttpError` enums, `handler timer`, `resume`, event
read/export, constraint enforcement) are scoped to the next rc.

### Runtime

- `queue.publish` / `topic.publish` / `store.<table>.query` return a
  proper `Result` instead of a bare `:ok` / bare list, so `!`/`?` unwrap
  them instead of crashing with an opaque `Erlang error: :if_clause`
  (skein-testing#17, #24). `publish` returns `{:ok, name}` (matching the
  spec's `Result[String, PublishError]`); the spec's `store.query`
  signature is corrected to `Result[List[T], StoreError]` (query can fail
  on an unknown filter field, which `List[T]` could not represent).
- `req.json[T]` atomizes schema-declared keys via a shared
  `Skein.Runtime.JsonSchema` module, so typed field access (`body.field`)
  works like the `llm.json[T]` path instead of crashing with a `KeyError`
  on the string-keyed map (skein-testing#2).
- `skein run` mounts every module's HTTP handlers behind one server
  (`Router.build_multi`) and registers all background handlers, instead of
  picking a single module and 404-ing the rest of a multi-module project
  (skein-testing#21).

### Compiler

- A module-level `fn` called from a nested agent's phase handler (or helper
  `fn`) now compiles: module fns are inherited as local functions of the
  agent's BEAM module, rather than lowering to an unbound variable and
  crashing `core_lint` (skein-testing#8).
- `if`/`else` (and `elif`/`then`/`switch`/`case`/`cond`/`unless`) emit a
  dedicated E0010 pointing at `match` on `Bool`, instead of the misleading
  "Unknown identifier — did you mean to declare this variable?"
  (skein-testing#5).

### Test LLM backend

- `llm.json[T]` synthesizes a value conforming to the requested schema `T`
  (was a fixed `{action, amount, reason}` map), so structured output is
  testable for any type (skein-testing#4).
- `llm.stream` is implemented on the test backend, so streaming runs
  offline like `chat`/`embed` (skein-testing#19).
- `llm.json` recovers JSON wrapped in a code fence or surrounding prose
  before failing with `:parse_failed` (skein-testing#27).

### CLI & DX

- `skein new` scaffolds a `.gitattributes` Linguist override so `.skein`
  renders with highlighting on GitHub (skein-testing#7) and a project
  `.mcp.json` so MCP-aware agents pick up the Skein server zero-config
  (skein-testing#12).

### Docs

- The generated `AGENTS.md` / `llms.txt` primer stops teaching patterns
  that crash (store not-found now matches `Err(_)`; `tool.call` is shown
  unwrapped) and promotes the highest-impact gotchas — effects return a
  `Result`, no `if`/`else`, `store.get` not-found is `Err(_)`; the false
  "agent fns callable from external code" claim is corrected
  (skein-testing#10).

## v1.0.0-rc.2 (2026-06-12)

The **second 1.0 release candidate** — the rc.1 soak audit (`/release-readiness`) plus an adversarial code review of its own fix PR (#230), closing the entire v1.0.0 Release GA milestone. The soak continues on this rc, which actually contains the fixes.

### Language & Compiler

- A guarded match arm with a block body no longer crashes the analyzer with a raw `ArgumentError` (improper list in the unused-binding walker) (#231)
- `"${Foo}"` — an uppercase identifier in string interpolation — is a structured E0010 with a bind-it-first fix hint instead of an unstructured codegen `FunctionClauseError` reaching MCP/LSP (#232)
- W0001 (unused binding) no longer false-positives on bindings referenced only via string interpolation (#196), or only inside list/map literals (#233) — the old warnings carried a `_name` fix_code that would have broken the program
- Float literals with underscore grouping (`1_000.5`) emit structured **E0003** "Invalid number literal" with a fix_code stripping the underscores, instead of crashing the whole compile (#197); E0003 is now an emitted code (spec §7 updated; E0013 stays reserved)
- Dropped the unused `nimble_parsec` dependency — the lexer is, and always was, hand-written binary matching (#228)

### Examples

- All sixteen examples now check **diagnostic-clean**, enforced by a new test guard over `examples/**/*.skein` (#199)
- `semantic_search` performs a real RAG flow (stores the vector, grounds the answer in retrieved context); `refund_agent`/`incident_triage` decide phases by exact match on the LLM's one-word reply, so Denied/Failed and Escalate/Ignore are reachable and negated wordings can't mis-route; `skein_assistant` actually remembers conversation context (history fed into the prompt and appended); `stdlib_demo` tours List/Map/Option/Result and `word_count` counts words; `market_research/service` drops its unused `tool.use` declarations (#199)

### Spec & Docs

- Spec §7's E0002 row covers all three lexer emissions (unterminated string, expression in interpolation, unterminated interpolation); the spec banner reads **Version 1.0** for the frozen spec (#224)
- Runtime docs show the real API shapes: `get_state` starts `%{}`, events are keyed `:event`, `Store`/`StoreEcto.query` take filter maps and return bare lists (#223)
- README's flagship capability block compiles (unimplemented `methods:` removed) and the demo transcript uses `claude-opus-4-8` (#225)
- Compiler pages document the real generated surface (`__handler_N__` + `__handlers__/0` shape, queue namespace, actual parser messages, five analyzer passes) without the NimbleParsec myth (#226, #228)
- Language pages match the implementation: `Skein.CLI.compile/1`'s 3-tuple, test blocks live in modules, the W0004 value-level exhaustiveness warning, supervisor metadata semantics, float/int division dispatch, and a diagnostic-clean pubsub example (#227)
- Meta-docs caught up with the release: roadmap pages regenerated from `docs/ROADMAP.md`, the installer and auto-tagging marked shipped, ARCHITECTURE gains the Bedrock backend and the Linux aarch64 target, CONTRIBUTING/CLAUDE.md milestone lists synced, and the v1.0.0-rc milestone closed in `milestones.json` (#200)
- STABILITY's trace-export sentence reads as English again, in both copies (#229)

### Testing

- New guard: every example must compile with zero errors **and zero warnings**
- Example handler tests resolve handlers by route from `__handlers__/0` metadata instead of brittle positional `__handler_N__` names

## v1.0.0-rc.1 (2026-06-12)

The **first 1.0 release candidate**. The `/release-readiness` audit adversarially swept every docs page, spec section, and example against the implementation; both resulting milestones of findings — the readiness pass (#182–#195) and the v1.0.0-rc burndown (#205–#220) — are fixed. The language surface, the frozen spec, and the documentation now describe the same system.

### Language & Compiler

- List literal expressions compile: `[1, 2]`, `[]`, nested lists, and literals as call arguments — previously every list literal crashed codegen with a raw `FunctionClauseError` that escaped into the MCP/LSP diagnostic paths (#205)
- Pipe expressions compile per spec §4 rule 8: the analyzer and codegen both desugar `x |> f(args)` into `f(x, args)`, so pipes into local functions, stdlib calls, and chains all work end-to-end (#206)
- `queue.publish` is wired end-to-end (analyzer, codegen, scoped runtime capability checks)
- `llm.stream` accepts an optional `on_chunk` function-reference callback receiving `String` chunks
- Effect calls are arity-checked against their documented parameter lists (E0020), including inside agent handler bodies, which previously skipped inference entirely
- `transition()` and `stop()` outside agent handlers are structured compile errors (E0033, new E0036)
- String interpolation rejects `${expr}` with a clear structured error and a bind-it-first fix hint — the supported surface is `${ident}` with optional dot access (#209)
- Removed the uncallable `Map.get!` from the spec and stdlib reference; the fallback-lookup pattern is `Option.unwrap(Map.get(m, key), default)` (#208)
- Stdlib/spec alignment: `Instant.diff` returns a `Duration`, `Option.unwrap`/`Result.unwrap` are the non-raising two-arity forms, `process.spawn`'s named parameter is `task:`

### Runtime

- A duplicate `idempotent()` key in a schedule handler now skips silently as documented, instead of crashing the Schedule GenServer and dropping every schedule registration in the node (#207)

### CLI

- `skein.toml` parsing tolerates unknown keys, value forms, and table forms wherever they appear — the STABILITY.md forward-compatibility promise ("unknown keys are never errors") now holds, so config written for future 1.x versions parses on 1.0; parse errors remain for the known `[llm]` profile keys only (#220)
- `mix skein.*` aliases route through the CLI dispatcher: real error/warning output and non-zero exit codes on failure (#198)

### Spec & Docs

- Spec corrections to match the implementation: §6.5 `tool.list`/`tool.schema` and §6.11 `timer.*`/`process.spawn` return Result-wrapped values (#216, #217); the four `*.parse` signatures use `String` error sides instead of the never-defined `ParseError` (#218); §2.3's keyword list, the §7 error-code registry (now with a severity column), and §2.6's interpolation grammar are accurate; in-agent `resume()` removed (resume is the host-side `Agent.resume/2`)
- Every docs-site page audited and corrected against the implementation: agents.md documents the real state semantics (agent data flows through `memory.kv`; all examples compile-verified) (#210); supervisors are compile-time declarations emitting `__supervisors__/0` metadata for the host (#211); the stdlib reference's examples compile and their shown outputs are true (#212); compiler pages use the real APIs and call forms (#213, #214); ARCHITECTURE.md shows the actual supervision tree and drops the unimplemented checkpointing claim (#219)
- The stability policy no longer designates the unshipped `trace export` command as the trace interchange form (#215)

### CI & Tooling

- On-demand **Release Readiness** workflow plus the `/release-readiness` Claude Code dynamic workflow: the full pre-release pass (gates, toolchain e2e, adversarially verified docs/spec/example sweep) without tagging or publishing
- Release gates are prerelease-safe, so `-rc.N` versions flow through the same tag-and-build automation
- New **v1.0.0-rc Release** milestone (this candidate); the **v1.0.0 Release** milestone is re-pointed at the GA gate

## v0.3.0 (2026-06-11)

The **v1.0.0 Release milestone is complete** — this release packages every item that gated 1.0: the spec freeze, match guards, a production embeddings path, runtime reliability fixes, and the written stability policy — plus an Amazon Bedrock LLM backend. The release train continues to a 1.0 release candidate from here.

### Language & Compiler

- **Spec freeze for 1.0** (#155): every "Planned" annotation resolved — timer task bodies implemented (below); tuple destructuring removed from the grammar (typed records remain the way to bundle values; revisit in a 1.x revision); the planned-testing block (`Agent.run_sync()`, stub declarations, `agent.events`/`agent.final_phase`, anonymous fns) removed, returning in a 1.x revision with its own design pass; the §8.5 scenario example now asserts on its `given` binding instead of carrying a placeholder
- Guard expressions in match arms: `pattern if expr -> body` with contextual `if`; guard-safe expression subset enforced as the new `E0027`, non-Bool guards are `E0020`, and guarded arms no longer count toward exhaustiveness (#147)

### Runtime

- Timer task bodies (#155, spec §6.11): `timer.after(delay, "task", &fn)` / `timer.interval(every, "task", &fn)` run the referenced zero-parameter fn inside a supervised task on each fire (crash-isolated, like `process.spawn` bodies); named no-ops remain the no-`work` behavior; `timer.*` now supports named arguments (`delay_ms`/`every_ms`, `task`, optional trailing `work`)
- **Removed** the deprecated `Skein.Runtime.EventLog` facade (superseded by `Skein.Runtime.EventStore` since the unified event store shipped); compiled code already called EventStore directly — external callers should use `EventStore.log/4`, `EventStore.query/1`, and `EventStore.clear/0` (#156)
- `llm.json[T]` results are usable from compiled code: schema-declared keys atomize at the decode boundary (nested objects, arrays, enum-variant `oneOf` branches; `Map[K, V]` keys stay strings), fixing the runtime crash on field access like spec §8.4's `d.action` (#154)
- **Amazon Bedrock LLM backend** (#173): `Skein.Runtime.Llm.BedrockBackend` serves `llm.chat`/`llm.json`/`llm.stream` through the Bedrock Converse API (one wire shape across Bedrock-hosted model families) and `llm.embed` through InvokeModel for Titan/Cohere embedding models. Requests are SigV4-signed; credentials resolve from backend config, then the standard AWS env vars. Capability declarations keep the canonical model name and `model_map` remaps to the Bedrock model ID or inference profile. `skein.toml` accepts `backend = "bedrock"` with `region` and optional `base_url` for VPC endpoints
- `llm.embed` is production-ready through the OpenAI-compatible backend's `/embeddings` endpoint (Voyage AI in production, local embedding models in dev, selected per environment in `skein.toml`); embed trace spans now record `backend`/`base_url` (#146)
- Queue and topic handlers from compiled modules are subscribed at server startup, so `queue.publish`/`topic.publish` reach declared handlers in a running service (#121)
- All named runtime ETS tables are owned by the supervised `Skein.Runtime.EtsTables` process instead of whichever process touched them first, eliminating mid-run table loss (#118)

### CLI

- `skein new <dir> --backend anthropic|openai_compatible|test|bedrock` (default: `anthropic`) selects the `[llm]` profile written to the scaffolded `skein.toml`, so projects targeting a local OpenAI-compatible server, the deterministic test backend, or Bedrock start runnable without hand-editing config; help text and zsh completions cover the flag

### Documentation

- `docs/STABILITY.md`: the versioning and stability policy for 1.0 — stability classes for every public surface (language, error codes, metadata contracts, EventStore schema, `skein.toml`, schema derivation), release cadence, spec versioning, and the deprecation policy; linked from the README, CONTRIBUTING, and the docs site (#157)

### Editor & Tooling

- LSP annotation completions offer exactly the implemented spec §4.2 set (`@one_of` added; unimplemented `@pattern`/`@optional`/`@deprecated` removed) (#156)
- VS Code extension 0.1.4: the Skein logo is the file icon for `.skein` files under icon themes that support language icons (#162)

## v0.2.0 (2026-06-11)

The **Beta Release milestone is complete** — replay-driven testing, scope-enforced capabilities, local-model development, and editor quickfixes — plus the public-repo essentials (license, security policy, one-line installer) and a string-interpolation correctness fix.

### Language & Compiler

- **String interpolation coerces values to their text form** (#114) — `"value: ${n}"` with an Int now renders decimal digits instead of inserting the raw codepoint byte into the binary (`42` → `"42"`, not `"*"`). Non-String interpolated values coerce through a runtime to-string helper.
- **Scoped capability labels** (#69, #57) — for `memory.kv`, `event.log`, `process.spawn`, and `timer`, the capability parameter names a scope label (namespace/stream/pool/group) that the compiler threads into runtime calls; call sites are unchanged. Declaring the same scoped capability twice in a module or agent is the new structured **E0017**, and an agent's label overrides its module's inside the agent (spec §3.2). At runtime, calls outside the declared label are denied — parameterless declarations stay presence-only — and labels are recorded on trace spans (`pool:`, `group:`) and stored events (`stream:`). Spec §6.11 now documents the `process.spawn`/`timer` surface.
- **Enum value-level exhaustiveness warning** (#76) — new **W0004** fires when a variant arm matches on literal field values and no wildcard or bindings-only arm covers that variant. Enum-typed function parameters now reach exhaustiveness checking at all (previously skipped entirely), and dotted variant patterns (`Event.Charge(n)`) count as coverage.

### Runtime

- **Replay backend injection** (#73) — `Replay.with_replay/2` now actually intercepts LLM, HTTP, and tool-call effects, serving recorded responses with **zero live calls**. Recorded events are validated against the live call (model, method, URL, tool name) so out-of-sequence replays produce clear errors instead of wrong answers, and an exhausted trace is an error — never a fallback live call. LLM/HTTP/tool spans now record full response payloads, so live traces are replayable; record → JSON export → replay round-trips are proven end-to-end.
- **`process.spawn` task bodies** (#74) — `process.spawn("name", &some_fn)` runs the referenced zero-parameter local fn inside the supervised task; crashes stay isolated by the supervisor. `work` is the first optional effect parameter (trailing optionals can be omitted). Timer task bodies remain Planned.
- **Local LLM backends for dev** (#107) — the new OpenAI-compatible backend speaks `POST {base_url}/chat/completions` (Ollama, LM Studio, llama.cpp, vLLM, …). `[llm]` and `[env.<name>.llm]` profiles in `skein.toml` select the backend per environment and remap capability model names via `model_map` — source and capability declarations never change between environments. `skein run`/`skein test` resolve `--env`/`SKEIN_ENV`; LLM spans record `backend` and `base_url`; a down server is a structured `LlmError` naming the base URL. Docs: the new runtime/local-models page.

### Editor & Tooling

- **LSP code actions from structured errors** (#108) — diagnostics now carry `code`/`fix_hint`/`fix_code`, and quickfixes apply them in the editor: insert a missing token (E0001), add a missing capability line (E0012), delete an unused capability (W0002), rename an unused binding to `_name` (W0001).

### Distribution & Repo

- **One-line installer** — `curl -fsSL https://kormie.github.io/Skein/install.sh | sh`: platform detection, sha256 verification against the release `checksums.txt`, installs to `~/.local/bin`; `SKEIN_VERSION` pins a release and `SKEIN_BIN_DIR` overrides the destination.
- **MIT license, code of conduct, and security policy** are in place for public consumption.
- The post-MVP backlog is fully scoped into issues and milestones (#78), and the CI session-start hook tolerates a flaky hex.pm proxy.

### Testing

- Suite grew from 1,651 tests + 198 properties to **1,774 tests + 202 properties** at the beta milestone's close, including properties for replay sequencing, scoped-label permit/deny, and W0004 coverage; the interpolation fix added further coercion tests on top.

## v0.1.7 (2026-06-11)

The **Alpha Release milestone is complete** — this release packages everything that gated taking the repo public: the last spec-vs-implementation gaps in the language, runtime completeness for schedules and agent events, and a first-five-minutes DX pass across the CLI, test runner, and MCP server.

### Language & Compiler

- **Agents nest inside modules** (#63) — `module RefundService { agent RefundAgent { ... } }` compiles to its own BEAM module (`Skein.Agent.RefundService.RefundAgent`). The nested agent sees the module's `type` declarations (so `llm.json[Decision]` works in phase handlers — the derived JSON Schema verifiably reaches the LLM request, #70) and module-level capabilities apply to it. Agents never declare their own `type` blocks; nesting is the route (spec §3.7). The compiler now emits one BEAM module per construct in a file, and `skein build` writes each. `examples/market_research/single_file.skein` ships the single-file shape alongside the two-file one.
- **Enum variant construction completeness** (#96) — zero-field variants construct in expression position (`Status.Active`, bare `Active`, and `Status.Active()` all lower to `:active`, matching patterns). Unknown variants, wrong constructor arity, and wrong argument types are structured E0010/E0020 errors with closest-name fixes — no `core_lint` crashes remain.
- **Structured assertion failures** (#105) — a failing `assert` raises `Skein.Runtime.AssertionError` carrying the operator, both inspected operands, the rendered expression, and the assert's `file:line`; `skein test` FAIL lines print all of it. Scenario and golden tests inherit the behavior.
- **Capability checks cover test blocks** (#104) — `test`/`scenario`/`golden` bodies are now part of E0012 coverage and capability-usage accounting, so the fresh scaffold no longer warns on its own `tool.use` and missing capabilities in tests fail at compile time.
- **Effect error types are language surface** — `HttpError`, `StoreError`, `NotFound`, `LlmError`, and the other spec §6 types are known type names (`Result[String, HttpError]` was a false E0024); `store.<table>` usage now counts toward unused-capability analysis.

### Runtime

- **Schedule handlers auto-fire** (#71) — full 5-field cron matching (`*`, `n`, `a-b`, `*/n`, lists; weekday 0/7 = Sunday; standard DOM/DOW OR rule) on a configurable 1s tick, deduped to once per cron minute. Invalid cron expressions are rejected at registration. `skein run` services register schedule handlers at startup; `trigger/1` and a deterministic `tick_at/1` remain for tests.
- **Agent `emit` events persist** (#72) — events flush to the EventStore as `:user_event` records (tagged agent/instance/phase) after each handler completes and *before* the result is acted on, so events emitted ahead of a crash survive and `EventStore.query/1` sees them.

### CLI & Tooling

- **`skein new` initializes git** (#106) — cargo-style: `git init` by default (never nested inside an existing work tree; `--no-git` to skip; missing git doesn't fail the scaffold) and a baseline `.gitignore` always written.
- **`skein completions zsh`** (#101) — tab-completion for every subcommand, flag, `.skein`/directory positionals, and `trace --kind` span kinds, drift-tested against the help text. Install snippet in the README.
- **MCP `skein_compile_check` matches `skein test`** (#109) — warnings are included (new `Compiler.check_file/1` API), project mode checks `src/` and `test/`, and `ok` stays errors-only.

### Spec & Docs

- **Every spec section 8 example compiles with zero diagnostics** (#77), enforced by `spec_examples_test.exs` at full-compile strength. The sweep fixed real bugs in 8.4's phase machine (undeclared `Analyze -> Failed` transition, missing `Done` handler). Tuple destructuring is explicitly annotated Planned. Spec 8.4 now shows the nested-agent shape.

### Testing

- Suite grew from 1,547 tests + 195 properties to **1,651 tests + 198 properties**, including properties for cron firing counts and agent event flushing.

## v0.1.6 (2026-06-10)

Named arguments land in the language, and the project itself gets release and triage automation: green version-bump merges now tag and publish on their own, and issues/milestones are managed as code.

### Language & Compiler

- **Named arguments in calls** (#56) — `f(name: value)`, with named arguments allowed in any order after any positional ones: `describe(suffix: "three", name: "widget")`, `llm.chat(model: "claude-opus-4-8", system: "...", input: question)`. The analyzer validates names against the callee's declared parameters — same-module/agent functions plus the documented effect signatures (`llm.*`, `http.*`, `memory.*`, `topic.publish`, `trace.annotate`, `process.spawn`, `event.log`) — and rewrites every call into positional order at compile time, so there is no runtime cost. Misuse is the new structured `E0026` error family: unknown names (the `fix_hint` lists valid ones), duplicates, a positional argument after a named one, parameters filled twice, missing parameters, and callees without a known signature. The spec grammar, section 8 examples, language docs, and agent primer all teach the form.

### CI & Release

- **Releases are "merge one PR"** (#100) — merging a green version-bump PR to `main` now auto-tags `v<version>` and publishes the four-target binaries, the VS Code extension, a per-release docs snapshot, and the `llms*.txt` files. No manual tag step. Release runs only trigger from `main`; superseded PR runs auto-cancel while `main`/release builds never do. README gained build/release badges.
- **`bump-version` repo skill** — preflights the exact gates the release workflow enforces (version match across `mix.exs` files, dated changelog section, doc version banners) before the release PR is opened.

### Project & Triage

- **Issues and milestones as code** — bug/feature/chore issue forms auto-label `type/*` and `status/triage`; milestones are defined in `.github/milestones.json` and synced by workflow (Alpha Release = the public-repo gate, Beta Release = post-alpha hardening). `CONTRIBUTING.md` documents the triage flow and label glossary; PRs get a template.
- v0.1.5 field-testing feedback triaged into the roadmap (#101, #104–#109); removed a legacy hooks archive.

### Testing

- Fixed a flaky analyzer property test (`uniq_list_of` exhausting its retry budget on small candidate spaces).

## v0.1.5 (2026-06-10)

Cross-module tools work end-to-end, and the toolchain meets AI agents halfway: `skein new` scaffolds agent context, `skein mcp` serves the spec and compile checks over MCP.

### Language & Compiler

- **Cross-module `tool.call` works end-to-end** — tools are the one cross-module seam (spec §3.1), and the whole chain now functions: each tool's `implement` block compiles to a callable entry point (`__tool_impl_N__/1`, named in `__tools__/0` metadata), and `skein build` / `skein test` / `skein run` register every declared tool at module load. `examples/market_research`'s agent→service call — previously a guaranteed runtime tool-not-found — now executes.
- **Result and enum variant construction in expression position** — `Ok(x)`, `Err(e)`, `Event.Charge(n)`, and the spec §8.4 `ErrName.from(cause)` error conversion now compile (implement blocks use all four). `Err` patterns lower to `:error`, so pattern matching, construction, and the runtime's `{:ok, _} | {:error, _}` convention finally agree.
- **E0016: cross-module function calls are rejected at compile time** — functions are module-private; a qualified call like `Hello.greet(...)` from another module is now a structured error whose fix points at the tool seam. Stdlib calls, enum variant constructors, and declared tool error names are exempt.
- **Prefix unary minus** — `-x` parses, type-checks (Int→Int, Float→Float), and compiles.
- **Targeted parser errors for known names missing their token** — e.g. a tool `description` without its `:` now says `Missing ':' after 'description'` with the token as `fix_code`, instead of a generic unexpected-token error.

### CLI

- **`skein test` is a two-phase runner** — every file (`src/` before `test/`) is compiled and loaded before any test runs, so tests in `test/` can exercise tools declared in `src/`. Previously test files ran immediately after compiling, before the modules they depended on existed.
- **`skein new` scaffolds tests that actually test** — `src/main.skein` ships a co-located `test` block plus a `{Module}.Greet` tool, and `test/main_test.skein` exercises that tool through `tool.call(...)!`. The old scaffold duplicated the function under test, so breaking `src/` left the test green; now it turns both tests red.
- **`skein new` scaffolds agent context** — generates `AGENTS.md` with a compact Skein primer plus a `CLAUDE.md` pointer (`--no-agents` to skip); `skein agents` (re)generates the marker-delimited block in place without touching user content.
- **`skein mcp`** — an MCP server (JSON-RPC 2.0 over stdio) exposing `skein_spec_lookup`, `skein_docs_search`, and `skein_compile_check` (structured JSON errors with `fix_hint`/`fix_code`), so coding agents can look up the language and check sources without a checkout.

### Runtime

- **`http.post` / `put` / `patch` accept map bodies** — JSON-encoded automatically, matching the spec §8.4 implement pattern (`http.post(url, { customer: id })`), which previously crashed on a binary guard before the capability check.
- **Tool registry hardening** — registration from compiled metadata is idempotent, string input keys normalize to the declared atom fields, and non-map input against a schema with required fields is a validation error instead of a crash.

### Testing

- **Examples are executed, not just compiled** — the suite drives the `market_research` cross-module path end-to-end (registration → implement execution → agent suspend flow, fully offline via deterministic capability denial), so a registration regression turns CI red instead of failing in user demos.

### Spec & Docs

- **Module boundaries documented** (§3.1): tools are the only cross-module mechanism; §8.5 shows the co-located test pattern. The docs site covers tool registration, the new scaffold, and registering the MCP server with Claude Code and Cursor.

### CI

- **Node 24-ready GitHub Actions** — every workflow action bumped to its latest major (`checkout` v6, `setup-node` v6, `cache` v5, `upload-artifact` v7, `download-artifact` v8, `upload-pages-artifact` v5, `deploy-pages` v5, `action-gh-release` v3) ahead of GitHub forcing actions onto the Node 24 runtime on 2026-06-16. The release job's artifact-name -> file-path mapping is unchanged across the artifact-action majors.

### VS Code Extension (0.1.3)

- **Bundled with esbuild** — `src/extension.ts` is now compiled to a single `out/extension.js` (with `vscode-languageclient` inlined), so the `.vsix` no longer ships `node_modules`: 9 files / ~120 KB instead of 211 files, with faster activation. `tsc` remains as a typecheck-only `npm run check`.

## v0.1.4 (2026-06-10)

Fixes from v0.1.3 field testing.

### CLI

- **`skein new my-app` generates a valid module name** — hyphens (or anything else that isn't a letter/digit/underscore) in the project directory name produced `module Skein-tests {`, which doesn't compile. Names are now sanitized (`skein-tests` -> `SkeinTests`) and prefixed with `Skein` when they don't start with a letter.
- **Ctrl+C exits cleanly** — long-running commands (`skein lsp`, `skein run`) no longer drop into the BEAM `BREAK:` menu on Ctrl+C (`+Bd` in vm.args).

### CI

- **Prebuilt VS Code extension** — CI packages `skein-vscode.vsix` and attaches it to releases, so installing the extension is a download + `code --install-extension` instead of a local npm build.

### VS Code Extension (0.1.2)

- **The packaged extension actually loads** — `.vscodeignore` excluded `node_modules`, so the `.vsix` shipped without `vscode-languageclient`; the extension module failed to load, which broke activation, the palette commands ("command 'skein.restartServer' not found"), and the language client. Production dependencies are now packaged.
- **Supervised language server** — the GenLSP process tree (buffer, assigns, task supervisor, server) now runs under a `:one_for_all` supervisor, so a crash in a handler restarts the server instead of killing the whole VM.

## v0.1.3 (2026-06-10)

First-run UX release: fixes for the CLI paper cuts hit in real first-use sessions, plus `skein lsp` so editor support works with just the standalone binary.

### CLI

- **`skein lsp`** — the standalone binary now embeds the language server (stdio transport). The VS Code extension no longer needs an Elixir checkout.
- **Errors name the file** — compiler errors print `src/main.skein:3:` instead of `unknown:3:`, and CLI output includes each error's `fix_hint`.
- **Readable file errors** — `File not found: …` and `… is a directory — pass a .skein file, or use 'skein build …'` instead of raw `:enoent` / `:eisdir`.
- **`skein build` / `skein test` / `skein run` default to the current directory** — matching the README that `skein new` generates.
- **Unknown flags are rejected** — `skein build -v .` now errors with `Unknown option: -v` instead of treating `-v` as the project directory.
- **`skein build` prints the actual compile errors** for failing files (with hints), not just the file name.
- **`skein test` reports files that fail to compile** — previously a broken file was silently skipped and the run reported `0 passed, 0 failed`. Compile failures are now printed and fail the run.
- **Stray-source hint** — when `src/` has no sources but `.skein` files sit in the project root, the error says so and points at `skein compile <file>`.

### Compiler

- **Targeted hints for habits from other languages** — `;` explains that Skein has no semicolons; `return` explains that a function returns the value of its last expression.

### CI

- **Lighter PR binary builds** — pull requests build only the native Linux target (release-assembly smoke test) and skip artifact uploads; docs-only PRs skip the job entirely. The full four-target matrix still runs on `main` pushes and `v*` tags.

### VS Code Extension (0.1.1)

- **Command palette entries actually appear** — `Skein: Restart Language Server` and `Skein: Show Language Server Output` were registered but never declared in the manifest. They also work (with a warning) when the server is disabled.
- **Standalone-binary language server** — the extension launches `skein lsp` by default and only uses `mix skein.lsp` inside a Skein compiler checkout. New settings: `skein.lsp.serverCommand` (`auto`/`skein`/`mix`) and `skein.lsp.skeinPath`.

## v0.1.2 (2026-06-10)

Hardening release: full codebase audit resolution plus demo-readiness fixes across the compiler, runtime, examples, and docs.

### Compiler

- **String-literal match patterns** — `match s { "approve" -> ... }` previously crashed the BEAM compiler (`core_to_ssa` on OTP 28). String patterns now compile to proper Core Erlang binary patterns, and matches without a catch-all arm get an explicit `case_clause` failure clause.
- **`method!(args)` / `method?(args)` parsing** — the bang/question mark now binds to the call result, so `store.users.get!(id)` parses as unwrap-of-call. Previously every `.get!(...)` form in the docs produced a mangled parse.
- **Agent `state.field` access** — works in nested expression positions (let values, call arguments, match subjects), not just at the top level of a phase handler.
- **`store.<table>.get!` / `put!`** — let-it-crash store accessors, in the analyzer, codegen, and runtime (`Store.get!/3`, `Store.put!/3`).
- **Capability rename** — queue handlers require `queue.consume` and schedule handlers `schedule.trigger` (aligned with the spec). Declaring the old `queue.in` / `schedule.in` produces a targeted rename hint on E0012.
- **`fix_code` everywhere** — all parser, lexer, and analyzer errors now carry machine-applicable `fix_code` (audit follow-up).

### Runtime

- **Audit resolutions (2026-06-09)** — atom-exhaustion and ETS race fixes, supervised GenServer startup, HTTP method whitelisting, size-bounded EventStore, query filter validation, CLI structured errors. See `docs/AUDIT_2026-06-09.md`.
- **`process.spawn("name")` no longer crashes** — compiled task-name spawns run as supervised, traced no-op tasks (task bodies are a planned extension).
- **Anthropic backend honesty** — removed the silent `gpt-*` → Claude model rewrite; the requested model is passed through unchanged. Replaced the deprecated default model with current model IDs.
- **Timer hardening** — `Timer.reset_all/0` no longer stops the supervised GenServer.

### Examples & Docs

- `examples/README.md` — a guided index of all fourteen examples with run instructions.
- All examples use current Anthropic model IDs (`claude-opus-4-8`); `semantic_search` documents that `llm.embed` needs an embeddings-capable backend.
- README flagship agent example rewritten to code that compiles as-is (and is kept compiling by tests for the constructs it uses).
- Install instructions point at GitHub Releases (binaries are published automatically on `v*` tags).
- `docs/ROADMAP.md` rewritten against a source-verified status pass; the docs site roadmap matches.
- Docs-site freshness pass: current model IDs, capability names, test counts, and the four-app umbrella layout.

### Test Suite

- **1,413 tests + 189 property-based tests**, 0 failures (up from 1,343 + 182). CI enforces format, `--warnings-as-errors`, and the full suite.

## v0.1.1 (2026-02-16)

### Features
- **Real type inference** — field access on typed records now resolves types; `user.email + 42` correctly produces type errors. Pattern bindings extract inner types from Result/enum variants.
- **Schema derivation** — nested user types generate fully resolved JSON Schema. Enum variants produce `oneOf` schemas. `Map[K,V]` generates `additionalProperties`.
- **Capability enforcement** — all 6 effect subsystems (HTTP, store, memory, LLM, tool, topic) now check capabilities at runtime.
- **Production LLM backend** — Anthropic integration with `llm.chat`, `llm.json`, `llm.stream`. Token-level usage tracking. Anti-corruption layer for provider-agnostic response format.
- **Enriched traces** — every effect call produces structured trace spans with timing, outcome, and token usage.
- **Persistent EventStore** — SQLite backend for events (opt-in, ETS remains default).
- **Replay engine** — recorded response injection for deterministic golden tests.
- **Agent memory isolation** — instance-scoped memory prevents concurrent agents from overwriting each other.
- **Tool input validation** — tool calls validated against declared schemas.
- **Error context enrichment** — structured error contexts with source locations.
- **Source text wiring** — `compile_file`/`compile_string` thread source text through for better error reporting.
- **Linux ARM64 builds** — `aarch64` added to distribution targets.

### Fixes
- Float division codegen generates correct Core Erlang
- Contextual keywords (`input`, `from`, `trace`) no longer reserved — usable as variable names
- Multiple `emit` in a single handler now collects all events (previously only the last was kept)
- Capability params codegen handles `ToolRef` and `Identifier` nodes
- Compiler test suite cross-app dependency resolved (181 failures fixed)

### Docs & Spec
- Spec sections 8.2–8.5 rewritten to use implemented syntax
- Landing page, quickstart, and overview rewritten for binary distribution
- Prebuilt binary install instructions added to README
- Comprehensive coverage for Tier 2 features in docs and tests

### Examples
- `market_research_agent.skein` — 5-phase competitive analysis agent with gather↔analyze loop
- `skein_assistant.skein` — stateful conversational agent for Skein code help

### Test Suite
- **1,316 tests + 182 property-based tests**, 0 failures (up from 1,176 + 182 in v0.1.0)

## v0.1.0

Initial release. Full compilation pipeline, 12 language constructs, stdlib, CLI, LSP, docs site.
