# Skein Post-Wave-B Sanity Check: Goals, Roadmap, and Factor Quality

**Date:** 2026-07-02
**Scope:** Full audit of the codebase against its stated goals (`docs/skein_first_principles.md`, `docs/SKEIN_SPEC.md` §4.3, CLAUDE.md design constraints), of the remaining roadmap (`docs/ROADMAP.md` Waves A–F), and of the codebase's own maintainability for an agent developer. Follows the source-verified, severity-ranked format of `docs/AUDIT_FIRST_PRINCIPLES.md` (2026-02-11) and the 2026-06-19 contract audit.
**Method:** Every claim below was verified against the code at `main` = `822c2be` (the B4/#293 merge that completed Wave B). Candidate findings were adversarially probed through `Skein.Compiler.compile_string/1` before being filed; refuted candidates are recorded as refuted.
**Baseline:** full umbrella `mix test` green at `822c2be`: **2,363 tests + 209 properties, 0 failures** (compiler 1,390+93 in 12.4s; runtime 737+115 in 45.9s; LSP 60; CLI 176+1; 64s wall total).

---

## Executive summary

Wave B did what it claimed. The soundness bridge — *analyzer-accept ⇒ Core Erlang ⇒ BEAM compile ⇒ load* — held against every adversarial probe in this audit, argument typing catches wrong-typed calls in fn, handler, agent-handler, and tool-implement bodies alike, records are nominal, `?` genuinely early-returns, and golden tests genuinely replay recorded traces. Three findings from the February first-principles audit are now formally stale (replay, instance-scoped memory, spec-examples-don't-compile), and one premise in this audit's own task brief was stale too (there is no stray `erl_crash.dump`).

But the second half of the Wave B invariant — *"typed values cannot silently cross incompatible boundaries"* — still has four confirmed leaks, all in the gap between "loads" and "runs correctly": a bare `Ok`/`Err` used as a value compiles silently to an atom; any record/fn/Option value in string interpolation compiles and then crashes at runtime with `:unsupported_interpolation`; `Err(LlmError.RateLimit(d))` patterns compile but can never match (C2, known); and the effect ABI can lie about shapes (`timer.cancel(ref)!` compiles against a `Result` that the runtime never returns — C1, known). The first two are new, previously untracked issues filed by this audit.

The bigger correction is to the **plan, not the code**: the roadmap, milestone descriptions, issue #279, and the scenario-environments design doc all still describe B1–B6 as open and provider-contract checking as "NOT landed." B6 landed both of #279's main bullets (provider contract type-checking with E0038, transitive purity). This document's companion edits re-baseline those surfaces, and the remaining #279 scope (llm.embed provider, `given` grammar reconciliation) is a P1 sliver, not a P0 epic.

Verdict on the release train: **v0.4.0 → v0.5.0 → rc.2 → GA sequencing stands.** Wave C's six premises were re-verified live today (all still true). Wave D remains the largest uncovered risk: both dogfood ports still call ambient `Uuid.new()`, which no longer exists in the stdlib, so **neither external repo compiles against main and no gate knows it**. On Wave E, the recommendation is to resolve #300 as **Alternative B (drop the FablePool-capable 1.0 promise; no v0.6.0)** — the reasoning is in Part 2.

---

## Part 1 — Current state vs. stated goals

Verdicts: **MET / PARTIAL / BROKEN / UNTESTABLE**, with evidence. The February audit's letter grades are shown for trend.

### P1: One Obvious Way — PARTIAL (was B-)

MET in the large: no `if/else`, no lambdas, no `return`, no exceptions, `--` comments, braces always — all still enforced; `match` is the only conditional and the analyzer now steers `if`/`switch`/`cond` users to it with targeted hints (`analyzer.ex:184-193`).

Residue, all known and tracked by #268:
- Two documented spellings of the same unwrap: spec §6 still documents `store.<table>.get!/put!` and `memory.get!` as *separate signatures* (`SKEIN_SPEC.md:665,667,682`) even though `get!(k)` and `get(k)!` are one parser desugar; `"get!"/"put!"` linger in `@effect_methods`/`@store_methods` (`analyzer.ex:115,129`) and `Store.get!/put!` exist in the runtime.
- `assert` still desugars in the parser to a `__assert__` call — the one violation of "no desugaring in the parser" (CLAUDE.md), and the `__assert__` dunder has already cost a Wave B special case (a dedicated `Call` clause because lowercase guards miss `_`-prefixed names — see MEMORY B4 notes). Fold into the factoring item (Part 3).

### P2: The Spec Fits in Context — MET (was A)

`SKEIN_SPEC.md` is 49,850 bytes (≈13–15K tokens); with the first-principles doc, ≈25K tokens total against the 128K budget. No action.

### P3: Types Are Contracts — PARTIAL, much improved (was D)

What the February audit called "the most important broken promise" is now substantially delivered *inside the language*:
- Call arguments are type-checked everywhere probed: local fns (`E0020`, probe: recursive call with wrong arg rejected), stdlib, effects (`memory.put(42, "x")` inside a tool implement body → `E0020` naming the parameter), agent phase-handler bodies (probe: `helper("nope")` → `E0020`), callbacks by arity/param/return (`analyzer.ex:4165-4172`).
- Records are nominal with no `map ~ user_type` escape (`analyzer.ex:4177-4191`); Option totality holds across construction/JSON/store/tool boundaries (B5); tool implement bodies check against `Result[output, error]` with field-by-field `Ok({...})` checking (B6, `analyzer.ex:1974-1999`); provider bodies check against exact contracts (`@provider_contracts`, `analyzer.ex:4831-4852`, E0038).
- Boundary guard works: `:unknown`/widened types cannot cross a declared fn return (`E0037`, probe-verified for `Err`-as-value at a boundary and for widened match arms — the arm mismatch is even caught earlier as `E0020`).

Confirmed remaining holes (beyond the sanctioned `:dynamic` seams the roadmap already owns via C1/C2/C3/C5):
1. **Bare `Ok`/`Err` as a value is accepted silently** — `analyzer.ex:2205-2206` deliberately exempts them from the unknown-constructor error, typing them `:unknown` with **zero diagnostics**. Probes: `let x = Ok` inside a fn body **compiles and loads**; so does passing `x` onward into a dynamic seam (`memory.put("k", x)` stores the atom `:ok`); so does `let x = Ok` in a `test` body. Only a declared fn-return boundary catches it (E0037). Codegen lowers the bare uppercase identifier to a bare atom. This is exactly the "silent nonsense" class Wave B's exit criteria target. **Filed as a new P1 issue.**
2. **String-interpolation segment types are never checked** — the analyzer accepts any expression type in `${...}`; codegen's coercion whitelist is binary/integer/float/atom with an explicit `erlang:error({:unsupported_interpolation, v})` fallback (`core_erlang.ex:2810-2824`). Probes: `"${h}"` where `h = &g` **compiles, loads, crashes at runtime**; `"${u}"` for a record value likewise. Worse, the atom arm means a bare `Ok` interpolates as the text `"ok"` — silent nonsense rendering. **Filed as a new P1 issue.**
3. **Opaque builtin error enums accept unmatchable variant patterns** — probe: `Err(LlmError.RateLimit(d))` compiles; the runtime returns `%Llm.Error{}` structs so the arm can never match. Known, correctly tracked as C2 (#297); re-verified live today.
4. **Effect payloads and the store remain untyped seams** — documented as `:dynamic` (`analyzer.ex:134-140,169-171`); probe: `fn f() -> Int { http.get(...)!.body }` is accepted by design. Owned by C1/C3/C5; no new tracking needed.

Schema derivation gaps from February (nested user types, enum variants, `Map[K,V]`) are fixed; the remaining schema problem is *validation* being dead (`llm.ex:391` atomizes only; tool output never validated) — C3 (#298), re-verified today.

### P4: Effects Are Visible, All Nondeterminism Controlled — PARTIAL (was B)

- Compile-time capability checking remains the strongest pass, and now extends through test/scenario/provider purity **transitively** (`collect_effect_sites` follows local calls and `&fn` refs with a visited set, `analyzer.ex:4675-4735`) — the February "runtime is swiss cheese" list is closed for tool/LLM/topic/scoped kinds, and `uuid.new()`/`instant.now()` are capability-gated effects (`analyzer.ex:105-109`), with ambient `Uuid.new()` removed from the stdlib (`analyzer.ex:349-350`).
- Replay/golden is **real** now: golden bodies execute inside `Replay.with_replay` (`core_erlang.ex:1511-1530`) and an e2e test proves a recorded LLM response is served instead of a live call (`test_construct_test.exs:334-361`). The February finding "replay is a trace reader, not a replay engine" is **stale**.
- Scenario-environment runtime authority (capability stack, `LiveEffectError`, `SpawnContext`) landed and is tested (C4 runtime half — confirmed by the 2026-06-19 audit and unchanged).

Still PARTIAL because the *shape* of an effect is not yet part of the contract: `timer.cancel` drifts three ways (analyzer `Result[String,String]` at `analyzer.ex:162`; runtime bare `:ok` at `timer.ex:180`; spec `-> ()` at `SKEIN_SPEC.md:802`) — probe: the `timer.cancel(ref)!` program **compiles and loads**, and would crash on unwrap at runtime. EventStore durability language is still false (moduledoc `event_store.ex:27-29` vs. no Repo/SqliteBackend at boot, `application.ex:11-20`). Both are correctly owned by C1 (#296) and C6 (#299); premises re-verified today.

### P5: Crash Gracefully — MET (was A-)

Supervised effect services (`application.ex`), ETS ownership under `EtsTables` (#118), agent `gen_statem` with crash-safe `emit` flushing (#72), `!` as the crash path. The February gaps (events lost on crash, schedule not firing) are closed. The one dishonesty here is durability *language*, not behavior — owned by C6.

### P6: Humans Read, Agents Write — PARTIAL (was C+)

Strong: 106 of 108 inline `%Error{}` constructions in the analyzer carry `fix_hint`, 103 carry `fix_code`; machine-applicable fixes have `span`/`edit_kind` with a reference applier (#150); the negative corpus is agent-extensible with zero tribal knowledge (drop a `.skein` file with an `-- expect: E00NN` header — auto-test, `negative_corpus_test.exs:40-61`); MCP `compile_check` returns errors+warnings; spec §8 examples compile with zero diagnostics (enforced by `spec_examples_test.exs`). The February "spec examples don't compile" finding is **stale**.

Confirmed agent-hostile residue:
1. **The error registry is wrong in the two copies agents actually read.** E0028/E0029 are emitted (`analyzer.ex:4588,4792`) but missing from spec §7 (the table jumps E0027→E0030, `SKEIN_SPEC.md:890-891`) **and** from the docs-site `compiler/errors.md`. An agent that hits E0029 and looks it up in the spec finds nothing. Known Wave A item but **had no tracking issue** — filed.
2. **E0020's fallback `fix_code` is a placeholder comment in non-Skein syntax**: `"// Fix the type mismatch"` / `"// Change expression type to X"` (`analyzer.ex:657-661`). `//` is not even a Skein comment. An agent that applies `fix_code` mechanically (which is the documented contract — "Exact code to add or change", spec §7) makes the program worse. Filed.
3. **The newline-`(` juxtaposition wart**: `let x = "s"` ↵ `(1 + 2)` parses as the call `"s"(1+2)` (`parse_postfix_chain`, `parser.ex:2283` — newline-blind). Post-B4 it is at least a structured rejection, but the diagnosis is misleading for the two-line program an agent actually wrote: probe shows `E0020 "This expression cannot be called as a function"` pointing at line 4 plus a spurious E0037, with a fix_hint about calling declared fns — nothing mentions that the newline didn't end the expression. The B4 property generator had to *work around* this wart (`codegen_soundness_property_test.exs:41-44`), which is the tell that it will bite code-writing agents. Filed (parse-level fix preferred pre-freeze; a targeted diagnostic is the fallback).

### CLAUDE.md constraints not covered above

- **Types generate schemas:** PARTIAL — derivation is complete (nested types, enum `oneOf`, `Map[K,V]`, circularity-safe) but emitted constraints/formats are dead on the validation side (C3).
- **Agent transitions compile-checked:** MET — E0030/E0031/E0032/E0033 all emitted and tested; phase-handler coverage enforced.
- **Errors are structured:** MET with the two P6 caveats above.

### The Wave B invariant itself (spec §4.3 rules 9–14)

*"An analyzer-accepted program never fails to generate/load"* — **MET**; no probe (bare constructors, cross-enum variants, recursive miscalls, handler/tool/agent bodies, interpolation, juxtaposition) produced a generate/load failure; codegen's former unbound-var fallbacks are now invariant raises (`core_erlang.ex:2472,2615,2630`) and the full suite proves them unreachable. The property gate is real but narrow — its generator covers module fns over Int/String/Bool plus one fixed feature block; no agents, handlers, tools, effects, guards, `?`, or interpolation (`codegen_soundness_property_test.exs:140-266`). Filed a P2 to widen it.

*"Typed values cannot silently cross incompatible boundaries"* — **PARTIAL**: holes 1–4 under P3 above.

---

## Part 2 — Remaining roadmap vs. goals

### Does every remaining item serve a stated goal, and are its claims still true?

**Wave A (v0.4.0 remainder):**

| Item | Goal served | Claims still true? | Priority check |
|---|---|---|---|
| #301 de-reserve `resume` | P6 honesty; STABILITY (last cheap moment) | Yes — still reserved (`SKEIN_SPEC.md:48`), still no construct (§6.8, `SKEIN_SPEC.md:762`) | P1 right. **Decidable now; recommend default A (de-reserve).** |
| spec §7 E0028/E0029 rows | P6 (registry honesty) | Yes — verified missing in spec §7 *and* errors.md | Was un-issued; **now filed** (P1). README count already softened (`README.md:374`) — the Wave A "README posture pending" note is stale. |
| #268 `!`/`?` position + `get!`/`put!` removal | P1 one-way | Yes — all cited locations re-verified | P2 right. |
| #262 dogfood gate (begins in Wave A) | Pillar 7 | Yes and sharper: ambient `Uuid.new()` is now *gone from the stdlib*, so both ports are **known-broken against main** with no gate to say so (`skein-testing/src/main.skein:114`, `fablepool.skein:991`; `ci.yml` runs umbrella only) | P0 right. Wiring the harness is now *more* urgent than when filed. |
| #271/#272 flakes (moved into v0.4.0) | Test-suite trust | #271's fix appears in-tree (`45c2d08` + `topic_test.exs:6-8` reset); #272 unresolved | Keep #272 open; **recommend closing #271 after a few green CI observations** on main. |

**Wave C (v0.5.0):** every premise was re-verified against today's source — C1 (`timer.cancel` 3-way drift: `analyzer.ex:162` / `timer.ex:180` / `SKEIN_SPEC.md:802`), C2 (`llm.ex` returns `%Llm.Error{}` structs; opaque builtin enums `analyzer.ex:382-401`; probe-confirmed unmatchable variant arm), C3 (`llm.ex:391` atomize-only), C5 (no Repo in supervision tree, `application.ex:11-20`; Ecto path caller-less), C6 (EventStore moduledoc still promises SQLite persistence nothing wires). All correctly scoped and correctly prioritized.

**The one stale plan surface: #279 (C4 analyzer half).** Its "NOT landed" list — provider contract type-checking, transitive purity — **landed in B6/#295** (closed 2026-07-01): `check_provider_contracts` with exact-signature E0038 (`analyzer.ex:479,4854-4881`), full `infer_type` over provider bodies with declared-return checking, and transitive `collect_effect_sites`. The same stale status text lives in `docs/design/scenario-capability-environments.md:108-115`, the v0.4.0/v0.5.0 milestone descriptions in `.github/milestones.json`, and ROADMAP's Wave B section. **Action taken with this audit:** roadmap + milestones.json re-baselined; re-scope comment posted on #279 (remaining: `llm.embed` provider support, `given`-grammar reconciliation — recommend P0→P1).

**Wave D (#262):** serves pillars 4/7 directly; see Wave A row — the gate is the only mechanism that would have caught the `Uuid.new()` breakage and is the top-priority item of v0.5.0 on this audit's evidence.

**Wave E / #300 (FablePool-capable decision):** now decidable, and this audit recommends **Alternative B — drop the promise from 1.0; do not create v0.6.0.** Reasoning against the goals: (1) none of P1–P6 requires content addressing — the substrate serves a *use case*, not a stated language goal; (2) the part of FablePool that stresses the *language* (Result/error/store/capability shapes, determinism) is fully exercised by the reduced dogfood program with its string-fingerprint stub — #262 keeps that value either way; (3) the substrate's real cost is a frozen cross-implementation canonical encoding (#256) — exactly the kind of surface the 2026-06-19 audit showed this project freezes prematurely at its peril; (4) GA is gated on soundness/honesty/dogfood, which are independent of it. Keep #245/#246/#250/#251/#256 in v1.1; promote one only if a checked-in conformance program proves it indispensable (the standing rule).

**Wave F:** unchanged; still gated behind everything above.

### Is every goal served by remaining work? (gap direction)

Goals with PARTIAL verdicts that had **no** roadmap item — all now filed (details in Part 4): bare `Ok`/`Err` (P3/P6), interpolation segment typing (P3/P6), newline-`(` juxtaposition (P6), E0020 placeholder fix_code (P6), spec §7 registry rows (P6), B4 gate breadth (invariant durability). The replay/golden question from the brief resolves the other way: the old audit's finding is stale, replay is real, and Wave D's determinism gates cover what remains — no new item needed.

### Sequencing

v0.4.0 → v0.5.0 → rc.2 → GA still matches the dependency graph (contract honesty before freeze; dogfood continuous). Two adjustments recommended: resolve #300 as B and delete the conditional v0.6.0 row from the train; and treat the four newly filed soundness/agent-writability P1s as v0.4.0 scope so "Truth & Soundness" exits with its own invariant actually clean. mix.exs remains `1.0.0-rc.4` — as the roadmap already says, the next tag should be `0.4.0`; release mechanics, not re-planned here.

---

## Part 3 — Factor quality (Claude-maintainability)

### File-size and cohesion hotspots

`analyzer.ex` is **6,260 lines** (~15 passes; grew ~900 lines across Wave B alone), `parser.ex` 2,976, `core_erlang.ex` 2,970. Where the pain is *actual*, per the Wave B commit history (every one of B1–B6 touched 3+ non-adjacent regions of analyzer.ex):

- **The hand-maintained registries are the coupling core.** The effect tables (`@effect_namespaces:94`, `@effect_methods:113`, `@effect_return_types:141`, `@effect_param_names:~717`, `@effect_param_types:~761`, `@store_methods:129`), `@stdlib_registry:196`, `@provider_contracts:4831`, `@builtin_type_names:~382` — plus codegen's parallel `@effect_runtime_modules`/`@stdlib_modules` (`core_erlang.ex:30,55`) — are the regions every wave must co-edit with distant pass code. **Recommendation: the highest-value "split" is already on the roadmap as C1 (#296)** — extracting a single effect-ABI registry is both the drift fix and the factoring fix. Do not do a separate speculative split first.
- **Clause-ordering is load-bearing and only documented in MEMORY.md**: `resolve_type`'s bare-`Map` clause must precede the generic `params: []` clause or it is silently shadowed (B5); `infer_type` helpers must sit after the catch-all clause (ungrouped-clauses = CI failure); codegen's stdlib clause must precede effect clauses; `spawn/3`'s two clause shapes must stay adjacent. These are symptoms of one 3,000-line `infer_type`/`resolve_type` clause space. A pass-group extraction (purity/providers ~4588–4950, capabilities ~4197+, agent checks ~5383+, warnings ~5700+ are already contiguous and separable) would turn ordering landmines into module boundaries. **Filed as a P2 chore explicitly sequenced *with or after* C1, not before** — respecting "don't fix what ain't broken": the suite is green and failures currently localize well (dedicated per-pass test files exist: `analyzer_boundary_test`, `analyzer_call_typing_test`, `analyzer_contract_test`, `analyzer_nominal_record_test`).
- `parser.ex`/`core_erlang.ex`: no split recommended. Recent parser changes (guards, interpolation normalization) were single-region; codegen's recent churn (B1 propagate wrapping) was localized to the test-fn generators.

### Single sources of truth (the multi-copy contract map)

| Contract | Copies | Drift in practice | Verdict |
|---|---|---|---|
| Effect ABI | analyzer tables; codegen module map; per-runtime-module shapes; spec §6 | **Yes** — `timer.cancel` 3-way; historical `[spec] align … with the runtime` commits (`3f35a7d`, `9293592`, `3db24de`); `List.reduce` callback-order bug (#254) | Generator/registry **pays for itself** → C1 (#296), already P0 |
| Error-code registry | analyzer moduledoc; spec §7; docs-site errors.md | **Yes** — E0028/E0029 present in copy 1, missing in 2 and 3, right now | Drift-test both directions → #202 subset in Wave D; rows filed as P1 |
| Stdlib registry | `@stdlib_registry`; codegen `@stdlib_modules`; runtime stdlib modules; spec §5 | Historical (#254, `Map.get!` removal #208) | Covered by #202/#262 fence-compilation + registry drift tests |
| Provider contracts | `@provider_contracts`; runtime resolution (`nondeterminism.ex`/`http.ex`/`llm.ex`); spec §4.3 r13 | None yet (B6 is 1 day old) | Watch; C1 registry should absorb it |
| Builtin type names | `@builtin_type_names`; spec §4.1/§6 | None observed | No change needed |

### Known-landmine inventory (MEMORY.md triage)

Fixable design debt: the newline-`(` parse (filed); `get!`/`put!` vestige (#268); `__assert__` dunder + parser-desugared `assert` (fold into the factoring item — an `AST.Assert` node removes the dunder special-casing); clause-ordering landmines (same item); `"// …"` placeholder fix_code (filed). Inherent/environmental, document-and-live: mise shims, Exqlite log noise interleaving totals, `mix run --no-start` quirks, cwd drift in test files, hex.pm availability. The February-audit gotchas about `input` keyword and `stop()` parens are now spec-documented contextual-keyword behavior, not landmines.

### Test-suite quality

- **Runtime and health:** 64s wall for 2,363 tests + 209 properties, zero failures — fast and green. **No change needed** on speed, including the blanket `async: false` across the runtime app (52 files): it is the correct posture while effect services are global GenServers, and the suite still finishes in ~46s.
- **Flakes:** #271 (Topic registry leak) has an in-tree fix (`45c2d08` + reset in `topic_test.exs:6-8`); #272 (schedule cron-timing property) remains the one known seed/load-dependent flake. A sweep of the other global services found `reset_all` hooks present on all of them (`timer.ex:200`, `schedule.ex:125`, `queue.ex:103`, `topic.ex:96`, `process.ex:184`, `idempotent.ex:86`) — the pattern issue #271 asked to audit is in place.
- **Fixtures:** ~194 inline `module …` sources across 60 compiler test files. This is *fine* — inline fixtures keep failures local and are the pattern agents already extend; the shared-fixture alternative would trade locality for reuse nobody needs. The conformance corpus is the right home for cross-cutting pins and is trivially extensible. **No change needed.**
- **Localization:** broken analyzer passes point at themselves (per-pass test files, exact-code negative fixtures). The B4 property gate is the one test whose failure output (a whole generated module) is expensive to localize — acceptable for a last-line gate.

### Dead/vestigial code

- `@contextual_keywords` in `lexer_property_test.exs:22` — defined, never read (fold into #268's sweep or the factoring item).
- `apps/skein_compiler/erl_crash.dump` — **does not exist**; stale premise, nothing to do.
- E0013 (documented reserved) and E0039 (free) are deliberate registry states, not dead code. `Store.get!/put!` are the only true dead runtime functions (#268).

---

## Part 4 — Synthesis: prioritized recommendations and roadmap mutation

Actions taken with this audit (same PR): this report; ROADMAP.md re-baselined (Wave B marked complete with residue list; C4 line corrected; Current State updated; new issues linked); `.github/milestones.json` v0.4.0/v0.5.0 descriptions corrected; re-scope comment on #279.

### New issues filed (each linked from the roadmap)

| # | Title | Priority | Milestone | Goal |
|---|---|---|---|---|
| [#309](https://github.com/kormie/Skein/issues/309) | Bare `Ok`/`Err` as a value compiles silently to an atom | **P1** bug | v0.4.0 | P3/P6 (Wave B residue) |
| [#310](https://github.com/kormie/Skein/issues/310) | Interpolation segment types unchecked — accepted programs crash with `:unsupported_interpolation` | **P1** bug | v0.4.0 | P3/P6 (Wave B residue) |
| [#311](https://github.com/kormie/Skein/issues/311) | Newline-`(` parses as a call of the previous expression; diagnosis misleading | **P1** bug | v0.4.0 | P6 (pre-freeze grammar decision) |
| [#312](https://github.com/kormie/Skein/issues/312) | Spec §7 + docs-site errors.md missing E0028/E0029 rows | **P1** chore | v0.4.0 | P6 (Wave A, previously un-issued) |
| [#313](https://github.com/kormie/Skein/issues/313) | E0020 fallback `fix_code` is a `//` placeholder comment | **P2** bug | v0.4.0 | P6 |
| [#314](https://github.com/kormie/Skein/issues/314) | Widen the B4 soundness-property generator (agents/handlers/tools/effects/interpolation) | **P2** chore | v0.5.0 | invariant durability |
| [#315](https://github.com/kormie/Skein/issues/315) | Analyzer factoring: registry extraction rides C1; pass-group submodules; `AST.Assert` node | **P2** chore | v0.5.0 | maintainability |

The #279 re-scope comment is at [kormie/Skein#279 (comment)](https://github.com/kormie/Skein/issues/279#issuecomment-4861331172).

### Explicit defer/delete calls

- **#300 → resolve as B; do not create v0.6.0.** Goal-based reasoning in Part 2. The canonical-substrate items stay v1.1.
- **#279 → narrow and downgrade P0→P1** (llm.embed provider + `given` reconciliation); the P0 mass it carried landed in B6.
- **#271 → close after green-CI observation**; the fix is on main.
- **No new work** for: suite performance, fixture consolidation, parser/codegen splits, spec size, replay/golden (stale finding), erl_crash.dump (nonexistent).

### The three sharpest risks to v1.0 GA (sound / honest / deterministic / dogfood-proven)

1. **The dogfood gate does not exist while the dogfood is already broken.** Both external ports fail to compile against main (ambient `Uuid.new()` removed) and nothing in CI knows. Every week without #262's harness, main drifts further from the two repos that define "dogfood-proven," and the eventual reconciliation grows. This is the same failure mode that made rc.1 premature — green first-party CI standing in for a bar it doesn't measure.
2. **The effect ABI is still three hand-synced copies (C1/C2).** The `timer.cancel` probe shows the analyzer can certify a shape the runtime never returns; the unmatchable `LlmError` variant shows the spec teaching patterns that silently never fire. Until one registry drives analyzer/codegen/runtime/spec, *every* new effect method is a fresh chance to reintroduce the class of bug Waves B/C exist to kill — and post-freeze, each one becomes permanent.
3. **Truth decay of the plan itself.** Within twelve days, the roadmap/milestones/issues/design docs went stale about what Wave B delivered — in the *optimistic* direction this time (#279 claiming work open that is done), but the 2026-06-19 audit caught the pessimistic version (claiming done what wasn't). A plan that must be hand-reconciled with source after every wave will eventually gate a release on wrong facts. The mitigations already in hand: this audit's re-baseline, #202's drift tests, and keeping "source wins over docs, docs win over memory" as the standing rule for every wave-exit review.
