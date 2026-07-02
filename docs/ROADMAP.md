# Skein Roadmap

**As of:** 2026-07-02 (post-Wave-B sanity check — see `docs/audits/2026-07-post-wave-b-sanity-check.md`)
**Based on:** the prior `/release-readiness` passes (2026-06-11/12), a source-verified dogfooding audit (2026-06-14/15) of the `skein-testing` and [FablePool](https://github.com/kormie/FablePool-skein) ports, the first-principles roadmap reset (2026-06-15) that replaced the `via` effect-override design with **scenario-scoped capability environments**, **and a source-verified soundness/contract audit (2026-06-19)** that re-sequenced the path to 1.0 around a contract-first dependency graph and corrected stale "done" claims (analyzer/codegen soundness is **not** complete; the runtime effect/schema/store/EventStore contracts are **drifted** from the spec). The audit's verified facts are cited inline below as `file:line`. **Re-baselined again 2026-07-02** by the post-Wave-B sanity check: Wave B (B1–B6, #290–#295) is **complete and source-verified** — the audit's adversarial probes could not break the analyzer-accept ⇒ BEAM-load bridge — with four residual soundness/agent-writability holes filed (#309–#311, #313) and one plan-truth correction (#279's "NOT landed" scope actually landed in B6; re-scoped to llm.embed provider + `given` reconciliation).

This is the forward-looking work list for Skein. Items are ordered by impact — the top items close the biggest gaps between the language's stated goals and its current reality.

## Release posture (re-baseline 2026-06-19)

**v1.0.0 GA is not imminent, and the next release is not another RC.** v1.0.0-rc.1 was tagged prematurely; the dogfooding audit reclassified GA from a docs-accuracy cleanup to a soundness + honesty + observability + conformance gate, and the 2026-06-19 source-verified audit found that **analyzer/codegen soundness is not yet established** and the **runtime effect/schema/store/EventStore contracts are drifted from the spec** — so the milestone scope was re-sequenced into a contract-first dependency graph. The release train is driven by two **pre-1.0 development milestones** (plus a conditional canonical-substrate milestone), then a true RC, then GA:

| Milestone | Carries | Status |
|---|---|---|
| **v0.4.0 — Truth & Soundness** | Wave A (truth reset) + Wave B (analyzer/codegen soundness, B1–B6 — **complete 2026-07-01**) + Wave B residue (#309 #310 #311 #313) | **shipped 2026-07-02** (tag v0.4.0) |
| **v0.5.0 — Runtime Contract & Dogfood** | Wave C (effect ABI / structured errors / schema / provider authority / store / EventStore, C1–C6) + Wave D (dogfood conformance gate) | **shipped 2026-07-02** (tag v0.5.0) |
| **v1.0.0-rc.5 — True release candidate** | Wave F — freeze + RC (#332 #320 #334); cut only when all blockers are green; no feature work | **active** |
| **v1.0.0 Release** | GA after rc.5 soaks | gated |

Milestones live in `.github/milestones.json` (synced by `.github/workflows/milestones.yml`). Dogfood conformance (Wave D) is a **continuous gate** that begins in Wave A and stays green through every later wave — not a final cleanup pass. Note: the RC milestone was renamed from `v1.0.0-rc.2` on 2026-07-02 — tags `v1.0.0-rc.2`–`rc.4` already exist from the pre-reset June train, so the next RC tag is `v1.0.0-rc.5`.

### The v1.0 thesis

> Skein is a small BEAM-targeted language for writing agentic services whose effects are explicit, typed, testable, replayable, and inspectable by both humans and LLM agents.

Seven release pillars: (1) sound type/runtime core; (2) capability-honest effects; (3) scenario-scoped capability environments; (4) deterministic/replayable testing; (5) human/agent CLI observability; (6) minimal canonical substrate (only if "FablePool-capable" stays in the pitch); (7) dogfood conformance across Skein, skein-testing, and FablePool-skein.

### Major design change: scenario-scoped capability environments (replaces `via`)

The `via &stub` / `via Module` "capability-bound implementations" design is **superseded** and **out of 1.0**. A scenario that tests a tool now declares the **complete capability environment** that tool may exercise, as a nested tree under the tool envelope, with local, typed, pure `implement` blocks:

```skein
scenario "refund sends id header" {
  capability tool.use(Billing.Refund) {
    capability http.out("api.stripe.com") {
      implement(req: HttpRequest) -> Result[HttpResponse, HttpError] { ... }
    }
    capability uuid    { implement() -> Uuid { ... } }
    capability instant { implement() -> Instant { ... } }
  }
  expect {
    let result = tool.call(Billing.Refund, { ticket_id: "t_123" })!
    assert result.status == "ok"
  }
}
```

Production callers still declare only `capability tool.use(T)` (the tools-only cross-module seam is preserved). No `via`, no `via Module`. Full design: [`docs/design/scenario-capability-environments.md`](design/scenario-capability-environments.md); the prior `via` design is retained, marked superseded, at [`docs/design/capability-bound-implementations.md`](design/capability-bound-implementations.md).

**Every item requires:**
- TDD — tests first, implementation second
- Property tests where input spaces are wide (StreamData for pure, PropCheck for stateful)
- Update `docs/ARCHITECTURE.md` and `docs/SKEIN_SPEC.md` if behavior changes

**Sizing key:** S = a few hours, M = half a day, L = a full day, XL = multiple days

---

## Current State

The compilation pipeline works end-to-end: lexer, parser, analyzer, codegen, and runtime are functional. The full umbrella suite passes (see CI for current totals). Sixteen example programs (thirteen single-file + the multi-file market_research pair and its single-file variant) compile, all covered by integration tests. The LSP, CLI, docs site, and binary distribution (Burrito, four targets) are operational. v0.3.0 shipped the complete original v1.0.0 milestone (spec freeze, guards, embeddings, Bedrock, the stability policy).

A lot of foundational surface area exists and works for first-party examples: type inference for field access and pattern bindings, schema derivation for nested types and enum variants, the production Anthropic LLM backend, runtime capability enforcement for tool/LLM/topic, agent instance-scoped memory, structured errors with `context`/`fix_code`, tool **input** validation, contextual keywords, string-literal match patterns, and the `queue.consume`/`schedule.trigger` capability naming. The **scenario-scoped capability environment runtime** (dynamic capability stack, `LiveEffectError`, `SpawnContext` propagation; `Dependencies` retired) and the **CLI render/JSON/trace** work also genuinely landed (#280–284).

**Wave B closed the soundness half (verified 2026-07-02).** Analyzer/codegen soundness is now established and adversarially probed: `?` truly early-returns (B1), `:unknown`/widened types cannot cross declared boundaries (B2, E0037), call arguments are type-checked for local/effect/callback calls in fn, handler, agent-handler, and tool-implement bodies alike (B3), the analyzer-accept ⇒ Core-gen ⇒ BEAM-compile ⇒ load bridge holds with codegen fallbacks turned into invariant raises plus a property gate (B4), records are nominal and `Option` is total across construction/JSON/store/tool boundaries (B5), and tool/provider bodies are checked against their declared contracts with transitive purity (B6, E0038). The residual holes found by the 2026-07-02 sanity check ([#309](https://github.com/kormie/Skein/issues/309)–[#311](https://github.com/kormie/Skein/issues/311), [#313](https://github.com/kormie/Skein/issues/313), [#318](https://github.com/kormie/Skein/issues/318), [#319](https://github.com/kormie/Skein/issues/319)) were all closed by the v0.4.0 close-out sweep — see "Wave B residue" below.

**The runtime contract drift is closed (Wave C + D landed 2026-07-02, the same day the drift was re-verified live).** The effect ABI now has a single authoritative registry (`Skein.EffectABI`, C1) with analyzer/codegen/spec drift tests; `llm.json[T]`, `req.json[T]`, and tool input/output validate through one recursive schema engine (C3); LLM/tool/provider/store/memory errors lower to the frozen structured-error ABI — an `Err(LlmError.RateLimit(d))` arm really matches (C2); store tables are typed and schema-checked (C5); the SQLite EventStore backend is on the ordinary append path, enabled by default under `skein run` (C6); `supervisor` declarations boot real OTP supervisors (#325); and the dogfood conformance gate runs on every change (Wave D / #262).

**That is not the whole picture, and the GA bar moved because of it.** The `/release-readiness` passes only ever swept the *first-party* spec, docs, and §8 examples — never the dogfooding testbeds, which is the entire point of `skein-testing` and FablePool. A source-verified audit of those ports (2026-06-14/15) surfaced ~27 live findings the sweeps structurally could not catch:

- **Soundness holes** — well-typed programs that crash or silently miscompute: effect calls are typed as their bare success type, so a missing `!`/`?` compiles then crashes ([skein-testing#1](https://github.com/kormie/skein-testing/issues/1)); `String + String` type-checks and crashes at runtime ([#252](https://github.com/kormie/Skein/issues/252)); `List.reduce` invoked its callback in the reverse argument order from its own spec ([#254](https://github.com/kormie/Skein/issues/254)); `!`-on-`Option` slips through `test` blocks ([#253](https://github.com/kormie/Skein/issues/253)); unknown effect methods leak `unbound_var`/`:if_clause` ([skein-testing#33](https://github.com/kormie/skein-testing/issues/33)).
- **Spec lies** — the spec's own §8.2 example uses an `Err(NotFound)` pattern that can never match ([skein-testing#3](https://github.com/kormie/skein-testing/issues/3)); `req.json[T]` is documented to validate `@min`/`@max`/`@one_of` but does not ([skein-testing#25](https://github.com/kormie/skein-testing/issues/25)); `resume` and the `timer` callback are documented but unreachable ([skein-testing#20](https://github.com/kormie/skein-testing/issues/20), [#18](https://github.com/kormie/skein-testing/issues/18)).
- **Missing capabilities** — porting a real signed/content-addressed protocol hit a wall: no closures ([#248](https://github.com/kormie/Skein/issues/248)), no crypto/bytes/encoding ([#245](https://github.com/kormie/Skein/issues/245)), no `Int` modulo/bitwise ([#246](https://github.com/kormie/Skein/issues/246)), no `String.join`/codepoints ([#250](https://github.com/kormie/Skein/issues/250)), no record update ([#251](https://github.com/kormie/Skein/issues/251)) or module constants ([#249](https://github.com/kormie/Skein/issues/249)).

Under the `docs/STABILITY.md` freeze, tagging 1.0 with these in place would make every one a permanent foot-gun. **GA is not imminent.** The contract-first waves below are the path; the GA bar is a **sound, honest, deterministic, dogfood-proven core**. The FablePool-capable canonical substrate question is **resolved (2026-07-02): [#300](https://github.com/kormie/Skein/issues/300) closed as Alternative B** — the promise is out of 1.0, the substrate items stay in v1.1, and there is no v0.6.0 milestone.

---

## Path to v1.0.0 — the contract-first waves (A–F)

Ordered as a dependency graph, not a feature theme list; earlier waves unblock later ones. TDD + property tests mandatory. Milestone mapping: **v0.4.0** = Waves A+B, **v0.5.0** = Waves C+D, **v1.0.0-rc.5** = Wave F (Wave E was retired when [#300](https://github.com/kormie/Skein/issues/300) resolved as Alternative B). Every 1.0 blocker must have measurable acceptance criteria and an automated release gate before it is considered done. The B/C status below is from the **2026-06-19 source-verified audit** — earlier "done" prose that source contradicts has been corrected.

**Wave A — Truth reset & surface cuts** *(1.0 blocker — **COMPLETE** with the 2026-07-02 close-out sweep)* — milestone v0.4.0:
- ~~Stop RC-promotion framing across `docs/ROADMAP.md`, the docs-site roadmap, `docs/STABILITY.md`, `CONTRIBUTING.md`, `README.md`.~~ — done (spec banner/site stability 2026-06-19; README + CONTRIBUTING corrected by 2026-07-02; the retired v0.6.0 row removed from CONTRIBUTING).
- ~~`docs/SKEIN_SPEC.md` in-flux flags~~ — done; the capability/effect list match is enforced going forward by C1's registry.
- ~~[#312](https://github.com/kormie/Skein/issues/312) — E0028/E0029 registry rows~~ — fixed (PR #324).
- ~~De-reserve or justify `resume`~~ — **de-reserved** ([#301](https://github.com/kormie/Skein/issues/301), decision A): removed from the lexer + spec §2.3; `resume` is an ordinary identifier, pinned by lexer test + positive-corpus fixture; agents remain resumed host-side (§6.8).
- ~~Correct EventStore durability language~~ — done: moduledoc, runtime docs page, and the STABILITY row now say the log is in-memory only and point at #299 (C6 owns the wiring). Dogfood-compat language verified honest (ROADMAP/Wave D state the ports are broken against main).
- ~~`#268` — `!`/`?` standardization + `get!`/`put!` deletion~~ — done: the pre-paren `method!(args)`/`method?(args)` forms no longer parse (targeted E0001 pointing at the postfix spelling), postfix `!`/`?` now continue the postfix chain, dead runtime fns deleted, spec §6 signatures collapsed, every repo Skein source swept to `get(k)!`.
- ~~[#272](https://github.com/kormie/Skein/issues/272) schedule flake~~ — de-flaked: deterministic tests pin crons to the simulated (past) date so no wall-clock tick can match; ~~[#271](https://github.com/kormie/Skein/issues/271) Topic flake~~ — closed after green-CI soak.

**Wave B — Analyzer/codegen soundness** *(1.0 blocker — **COMPLETE**, B1–B6 / #290–#295 merged by 2026-07-01 and source-verified by the 2026-07-02 sanity check)* — milestone v0.4.0. Invariant: *an analyzer-success program does not fail to generate/load because of a mismatch, and typed values cannot silently cross incompatible boundaries.* Delivered and probe-verified:
- **B1 (#290)** `?` truly early-returns (throw/catch at every user-body boundary; propagated error type checked, E0023).
- **B2 (#291)** `:unknown`/widened types are boundary-rejected (E0037); `:dynamic` is the only sanctioned seam; nominal/enum escape hatches removed.
- **B3 (#292)** argument typing for local/effect calls + `{:fn, params, ret}` callable type (contravariant params, exact arity) for `&fn` callbacks.
- **B4 (#293)** unknown refs/calls are site errors in every body kind (E0010/E0020); codegen unbound-var fallbacks are now invariant raises (`core_erlang.ex:2472,2615,2630`); property gate `codegen_soundness_property_test.exs` + positive corpus.
- **B5 (#294)** nominal records, total `Option` across construction/JSON/store/tool boundaries.
- **B6 (#295)** tool implement bodies check `Result[output, error]` field-by-field; provider contracts exact-match (E0038, `analyzer.ex:4831-4852`); purity transitive (`collect_effect_sites`, `analyzer.ex:4675`).
- Negative corpus: 41 fixtures with pinned codes; golden-replay activation verified e2e (`test_construct_test.exs:334-361`).

**Wave B residue** *(found by the 2026-07-02 adversarial probes — **ALL CLOSED** by the 2026-07-02 close-out sweep; the "silently cross" half of the invariant now holds)* — milestone v0.4.0:
- ~~[#309](https://github.com/kormie/Skein/issues/309) — bare `Ok`/`Err` as a value~~ — fixed (structured rejection).
- ~~[#310](https://github.com/kormie/Skein/issues/310) — interpolation segment types unchecked~~ — fixed (interpolation is typed, spec §2.6; E0020 with conversion hint).
- ~~[#311](https://github.com/kormie/Skein/issues/311) — newline-`(` juxtaposition~~ — fixed (PR #323: a `(` starting a new line never continues a call chain; spec §3.11 annotated).
- ~~[#313](https://github.com/kormie/Skein/issues/313) — E0020 placeholder `fix_code`~~ — fixed (PR #326: `fix_code` is applicable Skein or nil, never prose; sweeps enforce it).
- ~~[#318](https://github.com/kormie/Skein/issues/318) — expression-termination grammar audit~~ — done: spec §3.12 pins the newline rule for every postfix/infix production; line-initial `!`/`?`/`[` no longer continue the previous expression (the `!` steal was a silent-misparse hazard — prefix not is also `!`); `parser_termination_test.exs` pins every rule.
- ~~[#319](https://github.com/kormie/Skein/issues/319) — dead declared surfaces~~ — done *(rescoped 2026-07-02, owner decision: supervision is core to the agent thesis)*: tool `policy` blocks are **cut** (grammar/AST/spec removed; parsing one is a structured error); `supervisor` **stays** — its declaration contract is pinned in spec §3.9 as the frozen surface, and the runtime wiring landed as [#325](https://github.com/kormie/Skein/issues/325) (v0.5.0, below).

**Wave C — Runtime ABI, schema, capability authority & storage honesty** *(1.0 blocker — **COMPLETE**, C1–C6 landed 2026-07-02)* — milestone v0.5.0. Make the runtime expose exactly the contract the analyzer and spec claim. The 2026-06-19 audit found **C4 HONEST/CONTRACT-MET (runtime side)** and **C1, C2, C3, C5, C6 DRIFTED**; the v0.5.0 wave closed all of them:
- ~~**C1 — authoritative effect-ABI matrix**~~ — **landed 2026-07-02** ([#296](https://github.com/kormie/Skein/issues/296)): `Skein.EffectABI` is the single registry; the analyzer's effect/store/provider tables and codegen's module/scope maps are derived from it, spec §6 signatures are drift-tested both directions (`effect_abi_test.exs`), and the runtime ABI-matrix (`effect_abi_matrix_test.exs`) pins every method's live success/failure shape with registry-enforced completeness. Contract fixes: `timer.cancel` → `Result[String, String]` (`Ok` = ref, idempotent), `event.log` → `Result[String, String]` (`Ok` = event name; scope denial visible).
- ~~**C2 — one structured-error ABI**~~ — **landed 2026-07-02** ([#297](https://github.com/kormie/Skein/issues/297)): the builtin effect error enums (`HttpError`/`LlmError`/`ToolError`/`StoreError`/`MemoryError`/`PublishError`/`NotFound`) are real `EnumDecl`s materialized from the C1 registry — variants validate like user enums (unknown variant/wrong arity are structured errors) and lower to snake_case atoms/tuples (`{:rate_limit, ms}`, `{:denied, reason}`, …). The runtime converts its internal `%Llm.Error{}`/`%Tool.Error{}` structs to the ABI at every public boundary (`to_abi_result/1`), so `Err(LlmError.ProviderError(code, msg))` and `Err(ToolError.ValidationError(t, violations))` arms really match; store-`put`/`query` and memory-`put` failures are structured (`{:failed, reason}`/`{:denied, reason}`), never bare strings. The variant registry is pinned by `structured_error_abi_test.exs` + the ABI matrix, frozen in `docs/STABILITY.md`, and the blocked-live `LiveEffectError` raise is documented and **frozen as intentionally uncatchable** (spec §3.10).
- ~~**C3 — one recursive schema engine**~~ — **landed 2026-07-02** ([#298](https://github.com/kormie/Skein/issues/298)): `Skein.Runtime.JsonSchema.validate/2` + `decode/2` recursively enforce everything the derived schemas emit (nested objects/arrays, `required`, `enum`, min/max, `uniqueItems`, uuid/date-time/email/uri formats, `oneOf`, `additionalProperties`), shared across `req.json[T]`, `llm.json[T]` (schema violations are `Err(LlmError.InvalidSchema(violations))`), tool input, AND tool output (a wrong-shaped implementation result is `Err(ToolError.ValidationError)` with `output:`-prefixed violations).
- **C4 — scenario-provider soundness & capability authority:** the runtime dynamic capability stack, resolution order (`implement → replay → test-default → live → failure`), `LiveEffectError`, and `SpawnContext` propagation **landed and are contract-met** (`capability_stack.ex`, `nondeterminism.ex`, `spawn_context.ex`); `Dependencies`/`with_overrides` are retired. *(Corrected 2026-07-02:)* the analyzer half — provider contract type-checking (E0038) + transitive purity — **landed in B6/#295**. ~~[#279](https://github.com/kormie/Skein/issues/279) remainder~~ — **landed 2026-07-02**: `llm.embed` resolves past a scenario `model` provider to the deterministic backend (`LlmResponse` is text-only, so no embed provider form exists — spec §6.4), and `given` is reconciled per the signed-off decision (kept; the home for seeding stateful scenario fixtures — spec §3.10 documents evaluation order/scoping, pinned by `c4_remainder_test.exs`).
- ~~**C5 — honest store contract**~~ — **landed 2026-07-02** ([#255](https://github.com/kormie/Skein/issues/255)): store tables are TYPED — `capability store.table("games", Game)` (record type required, exactly one `@primary` field; violations are the new **E0043**); the analyzer types `get`/`put` as `Result[Game, StoreError]`, `delete` as `Result[PK, StoreError]`, `query` as `Result[List[Game], StoreError]` and argument-checks records/keys (E0020); codegen threads the record's derived JSON Schema into every `put` and the ETS store schema-checks each write (`StoreError.Failed`) — the chosen C5-internal backing is schema-checked ETS, not the Ecto revival. Both dogfood ports migrated (typed caps + nominal row construction).
- ~~**C6 — EventStore persistence & frozen shapes**~~ — **landed 2026-07-02** ([#299](https://github.com/kormie/Skein/issues/299)): opt-in SQLite persistence is wired onto the ordinary append path — `EventStore.append/1` async-writes through `Skein.Runtime.EventStore.Persistence` when enabled, `skein run` enables it by default (`<project>/.skein/events.db`, `--no-persist` opts out), `enable/1` reloads persisted history into ETS on restart (deduplicated by event id), restart durability is genuinely tested (`event_store_persistence_test.exs`: ETS wipe + fresh enable), and the persisted-and-reloaded JSON shape is pinned in the `Persistence` moduledoc. Shapes stay Pre-stable until the Wave F freeze (`docs/STABILITY.md`).
- ~~[#325](https://github.com/kormie/Skein/issues/325) — wire `supervisor` declarations into real OTP supervision~~ — **landed 2026-07-02** *(added 2026-07-02, owner direction: supervision is core to well-controlled agents)*: `Skein.Runtime.SupervisorHost` realizes `__supervisors__/0` as real OTP supervisors booted by `Skein.Runtime.Server` (so `skein run` services host them for as long as they live) — child targets resolve to compiled nested agents by the `Skein.Agent.<Module>.<Target>` convention, a child's brace-block entries are its `on start(...)` args (`restart:` selects the OTP policy), declared strategy (default `one_for_one`) and `max_restarts: N per M s` intensity are enforced, every (re)start appends a `:supervisor`/`:child_started` event, and `memory.kv` survives restarts (`supervisor_host_test.exs`). Additive on the surface pinned by #319/spec §3.9.

**Wave D — Dogfood conformance & release gate** *(1.0 blocker, CONTINUOUS — begins in Wave A, stays green thereafter)* — milestone v0.5.0:
- ~~[#262](https://github.com/kormie/Skein/issues/262) — the executable dogfood gate~~ — **landed 2026-07-02**: both external ports were migrated to main (capability-gated `uuid.new()`, nominal records, `scenario` envelopes for `tool.call`) and now pass against main (skein-testing 5/5, FablePool 18/18); checked-in reductions run on every PR (`conformance/dogfood/{dungeon,fablepool}` via `dogfood_corpus_test.exs`, exact pinned test counts); a dedicated CI job clones both upstream repos at the machine-readable pins in `conformance/dogfood.json` and executes their suites; release-readiness's toolchain e2e gained the same gate. FablePool's reduced conformance program keeps the string-fingerprint canonicalization stub (#300 → Alternative B — no content-addressing requirement in 1.0).
- ~~Compile every fenced `skein` block in the spec and docs site~~ — **landed 2026-07-02** ([#202](https://github.com/kormie/Skein/issues/202) subset): `docs_fences_test.exs` compiles every complete-module ```skein fence in the docs site + spec with zero diagnostics, and asserts error-demo blocks still emit their annotated codes; the negative corpus now snapshots the **complete** diagnostic set per fixture (exact code-set equality) plus the structured-diagnostic contract (JSON-serializable, no placeholder fix_code). Remaining Wave D breadth: runtime effect-shape tests for every method ride C1's registry ([#296](https://github.com/kormie/Skein/issues/296)); ~~property-test widening is [#314](https://github.com/kormie/Skein/issues/314)~~ — **landed 2026-07-02**: the B4 codegen-soundness generator now also produces guarded match arms (guard-safe ops incl. prefix `!`), string interpolation of in-scope scalar vars, `Float` params/lets/arithmetic, `?`-propagating generated Result fns (B1), `memory.put`/`get` + `uuid.new()` effect fns behind generated capabilities, nested agents with generated Phase enums calling module fns, tools with randomized input/output/errors, and `handler http` routes — same analyzer-accept ⇒ Core-gen ⇒ BEAM-compile ⇒ load gate (`codegen_soundness_property_test.exs`).
- ~~Factor-quality companion (sequenced with C1, never before): extract the hand-maintained analyzer registries into the C1 registry, split the contiguous analyzer pass groups into submodules, and give `assert` a real AST node~~ — **landed 2026-07-02** ([#315](https://github.com/kormie/Skein/issues/315)): the registry extraction shipped earlier with C1/#296 (`Skein.EffectABI`); the four contiguous pass groups identified by the 2026-07-02 sanity check are now submodules — `Skein.Analyzer.Purity` (E0029 purity + E0038/E0020 provider contracts), `Skein.Analyzer.Capabilities` (Pass 3, E0012/E0014/E0015/E0017/E0043), `Skein.Analyzer.AgentChecks` (E0030–E0034/E0036/E0039 transition/phase/handler/agent-only passes), and `Skein.Analyzer.Warnings` (W0001/W0002/W0004) — cutting `analyzer.ex` from ~6,460 to ~5,100 lines, with the shared inference/formatting helpers (`infer_type`, `types_compatible?`, `format_type`, location/span plumbing, …) staying in `Skein.Analyzer` as a minimal set of `@doc false` seams. Deliberately left in the main module: the `infer_type`/`resolve_type`/exhaustiveness core, Pass 2f scenario-envelope coverage, and the small E0035/W0003 walkers (not part of the audit's four groups). And `assert` is a first-class `AST.Assert` node end-to-end: the parser no longer desugars it to the `__assert__` dunder Call (the one 'no desugaring in the parser' violation), the analyzer/codegen/walkers match the node directly, and the Core Erlang lowering and diagnostics are unchanged.

**Wave E — retired (2026-07-02).** [#300](https://github.com/kormie/Skein/issues/300) resolved as **Alternative B**: the FablePool-capable promise is out of 1.0, there is no v0.6.0 milestone, and the train goes v0.5.0 → RC. The canonical-substrate items ([#256](https://github.com/kormie/Skein/issues/256), [#245](https://github.com/kormie/Skein/issues/245), [#246](https://github.com/kormie/Skein/issues/246), [#250](https://github.com/kormie/Skein/issues/250), [#251](https://github.com/kormie/Skein/issues/251)) stay in v1.1; any one is promotable only if a checked-in conformance program proves it indispensable. The reduced FablePool dogfood program (string-fingerprint canonicalization stub) remains in the Wave D gate — it exercises the language-stressing parts without the substrate.
- Scope controls: no general FFI; no signing/keygen/custody/secure-RNG in 1.0 ([#257](https://github.com/kormie/Skein/issues/257) is 1.1); no FablePool-specific store/log/provenance/grant/redaction APIs.

**Wave F — Stability freeze, true RC & soak** *(1.0 blocker — the ACTIVE gate since v0.5.0 shipped)* — milestones v1.0.0-rc.5 → v1.0.0 *(the RC milestone was renamed from v1.0.0-rc.2 on 2026-07-02: tags rc.2–rc.4 exist from the pre-reset June train, so the next RC tag is rc.5)*:
- [#332](https://github.com/kormie/Skein/issues/332) — the freeze itself: verify + declare every frozen surface with executable gates — grammar/keywords, diagnostic meanings + fields, effect ABI + error shapes, JSON Schema derivation + vectors, CLI/JSON/config, compiled-metadata classes, EventStore persisted vectors (flip the Pre-stable STABILITY row), and the pinned dogfood revisions — only after every preceding contract is executable and green.
- [#320](https://github.com/kormie/Skein/issues/320) — agent-writability benchmark *(added 2026-07-02: the P6 pitch gets a measurement — generate-compile-fix-loop harness reporting first-try compile rate and iterations-to-green; runs in release-readiness so RC quality is measured, not asserted)*.
- [#334](https://github.com/kormie/Skein/issues/334) — live-backend verification of `llm.stream` (dogfood finding kormie/skein-testing#26: 120s timeout against the real Anthropic backend while chat/json worked; blocker-fix scope, since CI never exercises live backends).
- No feature work in the RC milestone; run the exact GA release-readiness workflow and soak the same candidate.

### Cut from the minimal 1.0 surface (→ 1.1)

"FablePool-capable" was sharpened to "minimal substrate," moving these out of 1.0 (preserved on their issues, retargeted to v1.1):
- [#248](https://github.com/kormie/Skein/issues/248) closures — 1.1 unless the conformance suite (#262) proves them a hard blocker.
- [#257](https://github.com/kormie/Skein/issues/257) effectful crypto (RNG/keygen/signing), [#333](https://github.com/kormie/Skein/issues/333) content-addressed store tables (successor to the content half of [#255](https://github.com/kormie/Skein/issues/255), which C5's typed store tables consumed), [#141](https://github.com/kormie/Skein/issues/141) general FFI (the 1.0 crypto route is the internal `:crypto` wrapper in #245, not `extern`).
- Language ergonomics from dogfooding: [#251](https://github.com/kormie/Skein/issues/251) record update, [#249](https://github.com/kormie/Skein/issues/249) module constants, [#247](https://github.com/kormie/Skein/issues/247) enum variant payloads — 1.1 unless conformance proves one a hard blocker.
- `via` / `via Module` / behavioural stateful stubs (the superseded design) — reconsider in 1.1 only if still useful after scenario environments ship.

### Already shipped under the v1.0.0 Release milestone (rc-soak PR)

These items already shipped (the milestone shows 31 closed) — the rc-soak audit + docs-accuracy + Bedrock-hardening wave, **not** the GA gate (the GA gate is the contract-first waves A–F above). The compiler/examples items shipped on the rc-soak audit PR; the
documentation-accuracy wave (#223–#229, filed by the 2026-06-12 rc-soak readiness pass) rides
the same PR. The Bedrock production-hardening follow-ups (#178 #179 #180, plus the #236 SSO
work #179 split out) were pulled into scope from v1.1 on 2026-06-12:

- ~~[#196](https://github.com/kormie/Skein/issues/196) — **bug, p2:** W0001 misses string-interpolation usage (false positive with a program-breaking fix_code)~~ — fixed (interpolation tokens counted as references)
- ~~[#197](https://github.com/kormie/Skein/issues/197) — **bug, p2:** lexer crashes on float literals with underscore grouping (`1_000.5`)~~ — fixed (structured E0003 with fix_code)
- ~~[#198](https://github.com/kormie/Skein/issues/198) — **bug, p2:** `mix skein.compile`/`mix skein.test` print nothing and exit 0 on failure~~ — fixed (commit 76f0654, PR #204: aliases route through `Main.dispatch`)
- ~~[#199](https://github.com/kormie/Skein/issues/199) — **chore, p2:** ship the canonical examples warning-free and honest~~ — fixed (zero-warning guard in examples_test)
- ~~[#200](https://github.com/kormie/Skein/issues/200) — **chore, p2:** meta-docs a release behind (roadmap pages, ARCHITECTURE, README, CONTRIBUTING)~~ — fixed
- ~~[#223](https://github.com/kormie/Skein/issues/223)–[#229](https://github.com/kormie/Skein/issues/229) — **chore:** docs-accuracy findings from the rc-soak pass (runtime API examples, spec §7 E0002 row + banner, README flagship block, compiler/language/getting-started pages, STABILITY wording)~~ — fixed
- ~~[#179](https://github.com/kormie/Skein/issues/179) — **p1:** Bedrock AWS credential-chain resolution — M~~ — shipped (`:aws_credentials` integration behind `resolve_credentials/1`, started on demand: `AWS_PROFILE` files, EKS IRSA via the new `Skein.Runtime.Llm.AwsWebIdentityProvider`, ECS task roles, EC2 IMDSv2, EKS Pod Identity, with caching + refresh; chain region fills in when config/`AWS_REGION` miss)
- ~~[#236](https://github.com/kormie/Skein/issues/236) — Bedrock SSO / Identity Center credential resolution — M~~ — shipped (`Skein.Runtime.Llm.AwsSsoProvider`: modern `sso-session` + legacy inline profiles, the `aws sso login` token cache, portal `GetRoleCredentials`, profile `region` passthrough; an expired/missing session makes the missing-credentials error say `aws sso login --profile <name>`)
- ~~[#180](https://github.com/kormie/Skein/issues/180) — Bedrock ARN-form model IDs — S–M~~ — shipped (rejected before any request with a structured error naming the model-ID/inference-profile alternatives; inference-profile ARNs name the exact profile ID to use)
- ~~[#178](https://github.com/kormie/Skein/issues/178) — Bedrock real token streaming via `converse-stream` — L~~ — shipped (`Skein.Runtime.Llm.EventStream`: pure incremental AWS event-stream frame parser with CRC validation, property-tested against split frames and corruption; mid-stream exception events map to `Llm.Error` kinds; the shared `AsyncBody` receive loop also fixed the Anthropic SSE loop, which matched the wrong ref and could deliver out-of-order chunks)
- ~~[#234](https://github.com/kormie/Skein/issues/234) — **chore, p2:** parse interpolation segments into AST nodes instead of threading raw lexer tokens~~ — fixed (parser normalizes; per-walker special cases deleted; `${}`/handler/test-body/pattern crashes are structured errors; `${state.field}` works in handlers)
- ~~[#150](https://github.com/kormie/Skein/issues/150) — Code-action phase 2: `Skein.Error` span + `edit_kind` so any exact fix applies generically (phase 1 per-code mapping shipped with #108) — L~~ — shipped (machine-applicable fixes sweep-pinned; LSP generic path with per-code fallback; MCP compile_check surfaces the edits; `Skein.Error.Edit.apply_fix/2` reference applier)

### Shipped: v1.0.0-rc Release (tagged 2026-06-12 as v1.0.0-rc.1)

The complete 2026-06-11 readiness-pass milestone — spec↔compiler contract, compiler crashes, and docs-site accuracy (#182 #183 #184 #185 #186 #187 #188 #189 #190 #191 #192 #193 #194 #195), fixed on PRs #203/#204 and #221/#222.

### Shipped: the original v1.0.0 gate (all in v0.3.0)

- ~~[#114](https://github.com/kormie/Skein/issues/114) — **bug, p1:** Int string interpolation emits the raw codepoint~~ — fixed (PR #153), ships in v0.2.0
- ~~[#121](https://github.com/kormie/Skein/issues/121) — **bug, p1:** queue/topic handlers from compiled modules are never subscribed in a running service~~ — fixed (PR #158)
- ~~[#154](https://github.com/kormie/Skein/issues/154) — **bug, p1:** `llm.json` results decode with string keys but compiled field access reads atom keys~~ — fixed (PR #165: schema-directed key atomization at the decode boundary)
- ~~[#118](https://github.com/kormie/Skein/issues/118) — **bug, p2:** flaky CI — memory property test races shared `:skein_memory` ETS state~~ — fixed (PR #161: all named runtime ETS tables are owned by the supervised `Skein.Runtime.EtsTables`, never by transient callers)
- ~~[#147](https://github.com/kormie/Skein/issues/147) — Guard expressions in match arms — L~~ — shipped (PR #164)
- ~~[#146](https://github.com/kormie/Skein/issues/146) — Embeddings-capable LLM backend — M~~ — shipped (PR #166: OpenAI-compatible `/embeddings` proven from compiled source; Voyage AI for production via the same backend)
- ~~[#155](https://github.com/kormie/Skein/issues/155) — **chore:** Spec freeze — resolve every "Planned" annotation~~ — done (decisions recorded on the issue: timer bodies implemented, tuple destructuring + planned-testing block removed)
- ~~[#156](https://github.com/kormie/Skein/issues/156) — **chore:** Remove deprecated surface (EventLog facade + sweep)~~ — done (PR #168)
- ~~[#157](https://github.com/kormie/Skein/issues/157) — **chore:** Versioning and stability policy (`docs/STABILITY.md`)~~ — done (PR #169)
- ~~[#173](https://github.com/kormie/Skein/issues/173) — Amazon Bedrock LLM backend (Converse API) — M~~ — shipped (PR #170: SigV4 incl. session tokens, `model_map` → inference profiles, `skein new --backend`; follow-ups #178 #179 #180)

---

## Post-1.0 Backlog

**Issue:** [#78](https://github.com/kormie/Skein/issues/78) (tracking)

Everything below is post-1.0 (`.github/milestones.json`):

### Milestone: v1.1 — Hardening & Language

Cut from the minimal 1.0 surface by the reset, plus well-scoped gaps with no design unknowns:

- [#248](https://github.com/kormie/Skein/issues/248) — closures / anonymous functions — 1.1 unless conformance (#262) proves them a hard 1.0 blocker — L
- [#257](https://github.com/kormie/Skein/issues/257) — effectful crypto capability (secure RNG, key generation/custody, signing) — XL
- [#333](https://github.com/kormie/Skein/issues/333) — content-addressed store tables (hash-derived keys; depends on #245/#256) — M *(successor to the content half of [#255](https://github.com/kormie/Skein/issues/255), which C5's typed store tables consumed in v0.5.0; generic declared `@primary` key types already shipped there)*
- [#251](https://github.com/kormie/Skein/issues/251) record update · [#249](https://github.com/kormie/Skein/issues/249) module constants · [#247](https://github.com/kormie/Skein/issues/247) enum variant payloads — language ergonomics surfaced by dogfooding (1.1 unless conformance promotes one) — M each
- `via` / `via Module` / behavioural stateful effect stubs — reconsider only if still useful after scenario environments ship
- [#145](https://github.com/kormie/Skein/issues/145) — `llm.rerank` for RAG pipelines — M, depends on #146
- [#202](https://github.com/kormie/Skein/issues/202) — Docs/spec drift guard (the broader registry/generation work; the *compile-every-fenced-block* subset is pulled into Wave D / v0.5.0) — L
- [#240](https://github.com/kormie/Skein/issues/240) — LSP rename + find-references + workspace symbol search — L

### Milestone: v1.2 — Interop & Agent Workflows

Bigger design efforts, after the hardening wave:

- [#141](https://github.com/kormie/Skein/issues/141) — Erlang/Elixir FFI (`extern` keyword) — interop with existing BEAM libraries — XL
- [#144](https://github.com/kormie/Skein/issues/144) — Human-in-the-loop approval workflows — `suspend` before sensitive tool calls — XL
- [#143](https://github.com/kormie/Skein/issues/143) — Web trace viewer — browser-based exploration of trace data — L–XL
- [#171](https://github.com/kormie/Skein/issues/171) — Raxol CLI TUI — a 1.0 **nice-to-have** at most; the framework-neutral CLI render/JSON work (#284) already shipped and is the only CLI 1.0 requirement, so the interactive TUI defaults to v1.2 unless its gates (size/cold-start/no-NIF/teardown, per PR #239) pass during v0.5.0 — XL
- [#241](https://github.com/kormie/Skein/issues/241) — Native structural search + codemod for `.skein` (CLI + MCP) — XL

### Milestone: Future — Platform

Deliberately deferred (per CLAUDE.md "What Not To Do"); re-scope from scratch when pulled into active work:

- [#142](https://github.com/kormie/Skein/issues/142) — Hot code upgrades — OTP release upgrades without downtime
- [#148](https://github.com/kormie/Skein/issues/148) — Managed deployment platform — hosted Skein runtime
- [#149](https://github.com/kormie/Skein/issues/149) — Marketplace for tools/connectors — shareable tool definitions

---

## Completed Work (Reference)

All of the following are done and tested:

- Spec freeze (#155): zero "Planned" annotations remain — timer task bodies implemented (`timer.after/interval(..., "task", &fn)` runs the fn in a supervised task per fire); tuple destructuring and the planned-testing block removed from the 1.0 spec (decisions recorded on the issue)
- llm.json key atomization (#154), llm.embed production path (#146), deprecated-surface removal (#156), stability policy docs/STABILITY.md (#157)
- Amazon Bedrock LLM backend (#173, PR #170): `Skein.Runtime.Llm.BedrockBackend` speaks the Converse API — one wire shape across Anthropic/OpenAI model families on Bedrock; SigV4 via Req's built-in signer incl. STS session tokens; credentials from backend config or the AWS env vars with structured missing-credential/region errors; capability model names remap to Bedrock model/inference-profile IDs via `model_map`; `[llm] backend = "bedrock"` (region or `AWS_REGION`, optional VPC `base_url`); `skein new --backend anthropic|bedrock|openai_compatible|test` scaffolds activating profiles; `llm.embed` via InvokeModel (Titan/Cohere); stub-server tests assert live SigV4 signatures for an inference-free CI path; follow-ups: credential chain (#179), `converse-stream` streaming (#178), ARN model IDs (#180)

- Guard expressions in match arms (#147): `pattern if expr -> body` with contextual `if`; guards type-check as Bool with pattern bindings in scope and are restricted to a guard-safe subset (E0027 otherwise — no calls/effects/division/interpolation); guarded arms don't count toward exhaustiveness (analyzer + codegen catch-all); lowered to Core Erlang clause guards in module and agent paths; property pins compiled output to reference semantics
- Queue/topic handler subscription at server startup (#121): `Server.init/1` registers all background handlers from `__handlers__/0` — schedule registers, queue/topic subscribe — so compiled handlers receive published messages in a running service
- ETS table ownership (#118): all named runtime tables are created by the supervised `Skein.Runtime.EtsTables` owner (first child; unlinked `--no-start` fallback), fixing the class of flakes where a table died with the transient process that first touched it
- Int/Float/Bool string interpolation (#114): interpolation segments coerce at runtime — Ints render decimal digits, Floats use the `:short` format, Bools render `true`/`false`; binaries pass through unchanged

- Phases 1–7: full compilation pipeline (lexer, parser, analyzer, codegen)
- Phase 8a–8f: test infrastructure, Ecto/SQLite storage, HTTP server (Bandit + Plug), canonical examples, queue/schedule handlers, LLM streaming
- Phase 10: unified event store (+ optional persistent SQLite backend)
- Cross-module `tool.call` end-to-end (v0.1.5): `implement` blocks compile to exported entry points, CLI registers tools at module load; tools are the only cross-module seam (E0016 rejects cross-module function calls)
- Expression-position variant construction, call forms (v0.1.5): `Ok(x)`, `Err(e)`, `Event.Charge(n)`, `ErrName.from(cause)` — zero-field forms tracked in item 4
- Prefix unary minus; targeted parser errors for known names missing their token (v0.1.5)
- Agent context injection (v0.1.5): `skein new` scaffolds AGENTS.md, `skein agents` regenerates it, `skein mcp` serves spec lookup/docs search/compile checks over stdio
- Two-phase `skein test` runner (compile + load all of src/ and test/, then run); `skein new` scaffolds co-located tests + a cross-module integration test
- Type inference: field access through user-defined types, pattern bindings carry `Result`/variant inner types
- Schema derivation: nested user types, enum `oneOf`, `Map[K, V]` `additionalProperties`, circular-reference safety
- Production LLM backend: Anthropic Messages API (chat, json, stream) with retry and structured errors; current model IDs throughout
- Runtime capability enforcement: store, memory, HTTP, topic (name-scoped), tool (tool-name-scoped), LLM (model-scoped), presence checks for process/timer/event.log
- Agent instance-scoped memory (`{agent}:{instance}:{key}`)
- Error system: 22 error + 3 warning codes aligned with the spec; `context` and `fix_code` populated everywhere
- Codegen correctness: float-aware division, multi-`emit` accumulation, string-literal match patterns, explicit non-exhaustive-match failure clauses, `state.field` in nested positions, `method!(args)`/`method?(args)` parsing, `store.get!/put!`
- Tool input validation against generated JSON Schema (`validation_error`)
- Contextual keywords un-reserved (12 tokens usable as identifiers outside their construct)
- `queue.consume` / `schedule.trigger` capability naming (old names get a targeted rename hint)
- Standard library: 11 modules, 101 functions
- suspend/resume, respond.text/html, topic pub/sub, idempotent(key), trace.annotate, llm.embed, process.spawn, timer, event.log
- LSP: completions, hover, diagnostics, semantic tokens, document symbols, go-to-definition (+ request/response integration tests)
- CLI: new, build (`--output`), test, run, trace; structured errors for malformed flags
- Distribution: Burrito binaries (Linux x86_64/ARM64, macOS x86_64/ARM64), GitHub Release automation on `v*` tags
- Spec section 8 sweep (#77): every section-8 example now COMPILES with zero diagnostics (spec_examples_test upgraded from parse-only to full check_file); 8.4's phase machine fixed (Analyze -> Failed declared, Done handler added); effect error types from spec section 6 (HttpError, StoreError, NotFound, ...) registered as known type names; store.<table> usage now counts for W0002; tuple destructuring annotated Planned in the grammar
- zsh tab-completion (#101): `skein completions zsh` prints the script (subcommands + descriptions, per-command flags, .skein/directory positionals, trace --kind span kinds); drift test pins completions to the help text; README install snippet
- MCP `skein_compile_check` fidelity (#109): new `Compiler.check_file/1` returns errors AND warnings (full pipeline, no load); MCP result schema gains `warnings` (ok stays errors-only); project mode checks `src/` and `test/` like `skein test`
- Assertion failures show expected vs actual + location (#105): failing asserts raise structured Skein.Runtime.AssertionError (op/left/right/rendered expr/file:line); comparison operands bound and reported; CLI FAIL lines print the location; scenario/golden inherit via the shared lowering
- `skein new` git init + `.gitignore` (#106): cargo-style — init by default (skipped inside an existing work tree, with --no-git, or when git is missing), baseline .gitignore always written
- Agent `emit` -> EventStore (#72): handler-emitted events flush to the EventStore as :user_event (tagged agent/instance_id/phase) BEFORE the result is acted on, so they survive crashes; get_events/1 still reads gen_statem data; property pins N emits across M transitions = N stored events
- Schedule handler auto-firing (#71): periodic tick (1s, configurable) evaluates full 5-field cron matching (`*`, `n`, `a-b`, `*/n`, lists; DOM/DOW OR rule) with per-minute dedup; `Server` registers `:schedule` handlers from `__handlers__/0`; invalid crons rejected at registration; deterministic `tick_at/1` + firing-count property for tests
- Capability checks cover test blocks (#104): test/scenario/golden bodies feed both capability passes — effects inside tests require capabilities (E0012) and count as usage (no W0002 on the `skein new` scaffold; pinned by a scaffold-analyzes-warning-free CLI test)
- Enum variant construction completeness (#96): zero-field variants construct in expression position (`Status.Active`, bare `Active`, `Status.Active()` — all lower to `:active`, matching patterns); unknown variants and wrong constructor arity/types are structured E0010/E0020 with closest-name fix_code (no core_lint crashes remain)
- Types usable from agents (#70): module types are visible to nested agents and the derived JSON Schema flows into `llm.json[T]` requests from agent handlers (verified via recording backend); agents never declare their own `type` blocks — nesting is the route (spec §3.7)
- Replay backend injection (#73): an active `Replay.with_replay/2` context intercepts LLM (via `Llm.ReplayBackend`), HTTP, and tool-call effects, serving recorded responses with zero real calls; recorded events are validated against the live call (model/method/url/tool name) so out-of-sequence runs produce clear errors; LLM/HTTP/tool spans now record full response payloads (`response`, `response_body`/`status`) so live traces are replayable; replay state stays process-scoped
- Capability-parameter surface decision (#69): scoped capability labels (spec §3.2) — for `memory.kv`/`event.log`/`process.spawn`/`timer` the capability parameter names a scope label the compiler threads into runtime calls (call sites unchanged); one declaration per kind per module/agent, duplicates are E0017; spec §6.11 documents the `process.spawn`/`timer` surface
- Stream/pool-scoped runtime capability enforcement (#57): codegen threads the declared label into `process.spawn`/`timer.*`/`event.log` runtime calls (the `memory.kv` model); the shared `Capability.check_scoped/3` blocks calls outside the declared label (parameterless declarations stay presence-only); labels land on trace spans (`pool:`/`group:`) and stored events (`stream:`); `timer.after`/`timer.interval` now accept string task names as named no-ops; property pins permit/deny on exact label match over randomized capability sets
- `process.spawn` task bodies (#74): `process.spawn("name", &some_fn)` runs the referenced zero-parameter local fn inside the supervised task (spec §6.11); `work` is the first optional effect parameter (named-arg resolver supports trailing optionals); crashes stay isolated by the supervisor, proven from compiled Skein source; timer task bodies since implemented by #155
- Local LLM backends for dev (#107): `Skein.Runtime.Llm.OpenAiCompatibleBackend` speaks `POST {base_url}/chat/completions` (oMLX/Ollama/LM Studio/llama.cpp/vLLM); `[llm]` + `[env.<name>.llm]` profiles in skein.toml with `model_map` remapping capability model names (source and capabilities never change between environments); `skein run`/`skein test` resolve `--env`/`SKEIN_ENV`; llm spans record `backend`/`base_url`; server-down is a structured LlmError naming the base_url; stub-server tests give CI an inference-free path; docs page runtime/local-models
- LSP code actions from `fix_hint`/`fix_code` (#108, phase 1): diagnostics ship `code`/`fix_hint`/`fix_code` in `Diagnostic.data`; `codeActionProvider` advertised and `textDocument/codeAction` answers from the diagnostic alone — missing-token inserts (E0001), missing-capability line insertion (E0012, after the last capability or the module opening), unused-capability line deletion (W0002), unused-binding underscore rename (W0001); unmapped codes produce no action; phase 2 (error spans + edit_kind) moved to the backlog
- Enum value-level exhaustiveness warning (#76): new W0004 when a variant arm uses literal field patterns and no wildcard or all-bindings arm covers the variant; enum-typed fn params now reach exhaustiveness checking at all (previously `{:user_type, ...}` skipped it), and dotted variant patterns (`Event.Charge(n)`) count as coverage instead of false-missing
- Agent nesting inside modules (#63): `module Foo { agent Bar }` compiles to `Skein.User.Foo` + `Skein.Agent.Foo.Bar`; module types and capabilities apply to the nested agent; spec §8.4 and `market_research/single_file.skein` ship the nested shape
- Named arguments in calls (#56): `f(name: value)` for local fns and documented effect signatures; positional-then-named mixing, analyzer rewrites to positional order (E0026 for unknown/duplicate/misordered names), spec grammar + section 8 updated
- Release automation (#100, PR #102): green version-bump merges to `main` auto-tag and release (no manual tag step), README badges, per-release docs snapshots incl. `llms*.txt`; superseded PR runs cancel, main/release builds never do
- Docs site: Astro + Starlight at https://kormie.github.io/Skein/ with `llms.txt` endpoints
- CI: format check, `--warnings-as-errors` compile, full test suite
