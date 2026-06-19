# Skein Roadmap

**As of:** 2026-06-19 (roadmap re-baseline)
**Based on:** the prior `/release-readiness` passes (2026-06-11/12), a source-verified dogfooding audit (2026-06-14/15) of the `skein-testing` and [FablePool](https://github.com/kormie/FablePool-skein) ports, the first-principles roadmap reset (2026-06-15) that replaced the `via` effect-override design with **scenario-scoped capability environments**, **and a source-verified soundness/contract audit (2026-06-19)** that re-sequenced the path to 1.0 around a contract-first dependency graph and corrected stale "done" claims (analyzer/codegen soundness is **not** complete; the runtime effect/schema/store/EventStore contracts are **drifted** from the spec). The audit's verified facts are cited inline below as `file:line`.

This is the forward-looking work list for Skein. Items are ordered by impact — the top items close the biggest gaps between the language's stated goals and its current reality.

## Release posture (re-baseline 2026-06-19)

**v1.0.0 GA is not imminent, and the next release is not another RC.** v1.0.0-rc.1 was tagged prematurely; the dogfooding audit reclassified GA from a docs-accuracy cleanup to a soundness + honesty + observability + conformance gate, and the 2026-06-19 source-verified audit found that **analyzer/codegen soundness is not yet established** and the **runtime effect/schema/store/EventStore contracts are drifted from the spec** — so the milestone scope was re-sequenced into a contract-first dependency graph. The release train is driven by two **pre-1.0 development milestones** (plus a conditional canonical-substrate milestone), then a true RC, then GA:

| Milestone | Carries | Status |
|---|---|---|
| **v0.4.0 — Truth & Soundness** | Wave A (truth reset) + Wave B (analyzer/codegen soundness, B1–B6) | active |
| **v0.5.0 — Runtime Contract & Dogfood** | Wave C (effect ABI / structured errors / schema / provider authority / store / EventStore, C1–C6) + Wave D (dogfood conformance gate) | next |
| **v0.6.0 — Canonical Substrate** *(conditional)* | Wave E — created **only if** the FablePool-capable promise is kept (open decision); otherwise this work stays in v1.1 | gated on decision |
| **v1.0.0-rc.2 — True release candidate** | Wave F — freeze + RC; cut only when all blockers are green; no feature work | gated |
| **v1.0.0 Release** | GA after rc.2 soaks | gated |

Milestones live in `.github/milestones.json` (synced by `.github/workflows/milestones.yml`). Dogfood conformance (Wave D) is a **continuous gate** that begins in Wave A and stays green through every later wave — not a final cleanup pass. Note: `mix.exs` is at `1.0.0-rc.4` — a holdover from the pre-reset RC race; the next tag should be `0.4.0` (a version bump is release mechanics, tracked separately, and intentionally not part of this planning re-baseline).

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

**But "works for first-party examples" is not "sound and honest", and the 2026-06-19 source-verified audit proved several earlier "done" claims wrong.** Analyzer/codegen soundness is **not** established: `?` does not early-return (B1), `:unknown`/`:json` are universal top types with no public-boundary guard (B2), local/effect calls check arity only (B3), records are untagged maps and `Option` representation is inconsistent across boundaries (B5), and neither tool nor provider bodies are checked against their declared return contract (B6). The runtime contract is **drifted**: the effect ABI has three hand-maintained copies that disagree (`timer.cancel`), `llm.json[T]` does not validate, LLM/tool/provider errors leak raw Elixir structs that cannot be pattern-matched, the typed store is dead code, and the SQLite EventStore is an orphaned backend whose durability docs are false. Earlier-closed issues #259/#253/#260 cleared *symptoms* but left these *contracts* incomplete. The persistent-EventStore and `store.<table>.get!/put!` items previously listed as "done" are **partially** done at best.

**That is not the whole picture, and the GA bar moved because of it.** The `/release-readiness` passes only ever swept the *first-party* spec, docs, and §8 examples — never the dogfooding testbeds, which is the entire point of `skein-testing` and FablePool. A source-verified audit of those ports (2026-06-14/15) surfaced ~27 live findings the sweeps structurally could not catch:

- **Soundness holes** — well-typed programs that crash or silently miscompute: effect calls are typed as their bare success type, so a missing `!`/`?` compiles then crashes ([skein-testing#1](https://github.com/kormie/skein-testing/issues/1)); `String + String` type-checks and crashes at runtime ([#252](https://github.com/kormie/Skein/issues/252)); `List.reduce` invoked its callback in the reverse argument order from its own spec ([#254](https://github.com/kormie/Skein/issues/254)); `!`-on-`Option` slips through `test` blocks ([#253](https://github.com/kormie/Skein/issues/253)); unknown effect methods leak `unbound_var`/`:if_clause` ([skein-testing#33](https://github.com/kormie/skein-testing/issues/33)).
- **Spec lies** — the spec's own §8.2 example uses an `Err(NotFound)` pattern that can never match ([skein-testing#3](https://github.com/kormie/skein-testing/issues/3)); `req.json[T]` is documented to validate `@min`/`@max`/`@one_of` but does not ([skein-testing#25](https://github.com/kormie/skein-testing/issues/25)); `resume` and the `timer` callback are documented but unreachable ([skein-testing#20](https://github.com/kormie/skein-testing/issues/20), [#18](https://github.com/kormie/skein-testing/issues/18)).
- **Missing capabilities** — porting a real signed/content-addressed protocol hit a wall: no closures ([#248](https://github.com/kormie/Skein/issues/248)), no crypto/bytes/encoding ([#245](https://github.com/kormie/Skein/issues/245)), no `Int` modulo/bitwise ([#246](https://github.com/kormie/Skein/issues/246)), no `String.join`/codepoints ([#250](https://github.com/kormie/Skein/issues/250)), no record update ([#251](https://github.com/kormie/Skein/issues/251)) or module constants ([#249](https://github.com/kormie/Skein/issues/249)).

Under the `docs/STABILITY.md` freeze, tagging 1.0 with these in place would make every one a permanent foot-gun. **GA is not imminent.** The contract-first waves below (A–F) are the path; the GA bar is a **sound, honest, deterministic, dogfood-proven core**, with the FablePool-capable canonical substrate an **explicit open decision** (Wave E) rather than an assumed promise.

---

## Path to v1.0.0 — the contract-first waves (A–F)

Ordered as a dependency graph, not a feature theme list; earlier waves unblock later ones. TDD + property tests mandatory. Milestone mapping: **v0.4.0** = Waves A+B, **v0.5.0** = Waves C+D, conditional **v0.6.0** = Wave E, **v1.0.0-rc.2** = Wave F. Every 1.0 blocker must have measurable acceptance criteria and an automated release gate before it is considered done. The B/C status below is from the **2026-06-19 source-verified audit** — earlier "done" prose that source contradicts has been corrected.

**Wave A — Truth reset & surface cuts** *(1.0 blocker)* — milestone v0.4.0:
- Stop RC-promotion framing across `docs/ROADMAP.md`, the docs-site roadmap, `docs/STABILITY.md`, `CONTRIBUTING.md`, `README.md`. No page may claim v1.0.0 GA is imminent, call a mutable surface "frozen", or describe `via` as accepted 1.0 design. *(spec banner, site stability page corrected 2026-06-19; README posture pending.)*
- `docs/SKEIN_SPEC.md`: removed the unqualified "v1.0 frozen" claim; flag the scenario-testing surface (§3.10/§8.5), `given`, `resume`, `uuid`/`instant`, the effect/error ABI (§6), the error registry (§7), and the store contract (§6.2) as in-flux. The capability/effect lists in the spec must match implementation.
- Reconcile diagnostic-code ownership: **E0028/E0029 are implemented** (`analyzer.ex:3806,3941`) but **missing from the §7 registry** (jumps E0027→E0030); the README "24 codes" count is stale. Track as a spec-honesty blocker.
- De-reserve or justify `resume`: it is a reserved keyword (§2.3) with **no source construct** (§6.8) — decide before freeze (default: de-reserve; new reserved words are breaking after freeze). See the `resume` decision issue.
- Correct EventStore durability language (the live store is ETS; SQLite is an opt-in, currently **orphaned** backend) and dogfood-compat language (the external ports do **not** pass current main — there is no gate yet).
- `#268` — `!`/`?` position standardization + remove vestigial `get!`/`put!` baggage (one-way-to-do-things honesty polish).

**Wave B — Analyzer/codegen soundness** *(1.0 blocker — NOT complete; the earlier "mostly complete" claim was wrong)* — milestone v0.4.0. Invariant: *an analyzer-success program does not fail to generate/load because of a mismatch, and typed values cannot silently cross incompatible boundaries.* The 2026-06-19 audit found **B1, B2, B3, B5, B6 BROKEN and B4 PARTIAL**. Open blocker issues (each with acceptance criteria + gates):
- **B1 — true `?` propagation:** codegen emits `{error, e}` as a local value and does **not** early-return (`core_erlang.ex:1684-1710`); the analyzer never checks the propagated error type against the enclosing `Result` error (`analyzer.ex:2078-2137`). `?` on an `Err` currently continues executing.
- **B2 — eliminate escaping `:unknown`:** `types_compatible?(:unknown,_)`/`(_, :unknown)`/`(:json,_)` are universally true (`analyzer.ex:3376-3380`); the public-boundary guard the comment at `analyzer.ex:3408` claims **does not exist**; incompatible same-headed compounds widen to `:unknown` silently. (Earlier-closed #259 did **not** fully close this.)
- **B3 — local/effect/callback argument typing:** local calls and effects check **arity only**, never argument types (`analyzer.ex:2179-2201,944-976`); there is no callable/function type, so higher-order stdlib (`List.map/filter/reduce`) cannot reject a non-function or wrong-arity callback.
- **B4 — unknown-call & invalid-codegen rejection (PARTIAL):** many rejections exist, but codegen has unbound-var fallbacks (`core_erlang.ex:2466-2484`) and there is **no property test** asserting "analyzer success ⇒ Core gen ⇒ BEAM compile ⇒ module load."
- **B5 — total `Option` + nominal record representation:** records are untagged maps and `{:map} ~ {:user_type}` is universally true (`analyzer.ex:3399-3400`) — any map passes as any record; `Option` representation is inconsistent (`store_ecto.ex:194-198` and `tool.ex:283-292` return bare `nil`/value, not `:none`/`{:some,v}`, unlike the JSON path). (Earlier-closed #253 deferred field-level checking.)
- **B6 — tool & provider body return checking:** tool `implement` inference discards the result type (`analyzer.ex:1698-1714`); scenario providers are **never** type-checked against their effect contract (only purity/coverage); provider purity is **non-transitive** (`analyzer.ex:3879-3880`); the runtime accepts bare tool output unchecked.
- Plus: a **negative-fixture corpus** covering every B-hole with exact structured diagnostics, and **golden-replay activation** verification.

**Wave C — Runtime ABI, schema, capability authority & storage honesty** *(1.0 blocker)* — milestone v0.5.0. Make the runtime expose exactly the contract the analyzer and spec claim. The 2026-06-19 audit found **C4 HONEST/CONTRACT-MET (runtime side)**; **C1, C2, C3, C5, C6 DRIFTED**:
- **C1 — authoritative effect-ABI matrix:** one source of truth / generated registry for every effect method. Today three hand-maintained copies drift (`analyzer.ex` tables, `core_erlang.ex:26` runtime-module map, per-module runtime shapes) — e.g. `timer.cancel` is `Result[String,String]` (`analyzer.ex:153`), bare `:ok` at runtime (`timer.ex:155`), `-> ()` in spec (`SKEIN_SPEC.md:772`). Analyzer/spec/runtime drift must become a CI failure.
- **C2 — one structured-error ABI:** HTTP/store-`get`/memory-`get`/`NotFound` lower correctly, but **LLM, tool, and provider errors leak raw `%Llm.Error{}`/`%Tool.Error{}` Elixir structs** behind opaque builtin enums (`llm.ex:497`, `tool.ex:447`) — a user **cannot** match `LlmError.ProviderError(..)`/`ToolError.ValidationError(..)`. Store-`put`/`query` and memory-`put` are bare strings. The blocked-live `LiveEffectError` raise is **intentionally uncatchable** — document and freeze that decision.
- **C3 — one recursive schema engine:** `llm.json[T]` only parses+atomizes and does **not** validate (`llm.ex:391`, despite the docstring); tool **output** is never validated; `uniqueItems`/formats/nested element types are emitted but dead. Use one shared validator/coercer across `req.json[T]`, `llm.json[T]`, tool input, and tool output.
- **C4 — scenario-provider soundness & capability authority:** the runtime dynamic capability stack, resolution order (`implement → replay → test-default → live → failure`), `LiveEffectError`, and `SpawnContext` propagation **landed and are contract-met** (`capability_stack.ex`, `nondeterminism.ex`, `spawn_context.ex`); `Dependencies`/`with_overrides` are retired. The **remaining** C4 work is analyzer-side: provider contract type-checking + transitive purity (B6 / #279).
- **C5 — honest store contract:** the active store is **dynamic and untyped** — the analyzer does not know table `T` (`analyzer.ex:163-168`), the primary key is not Uuid-checked, and the Ecto typed-table path (`ecto_schema.ex`, `store_ecto.ex`, `migration_gen.ex`) is **dead code** with no production callers and no Repo in the supervision tree. Decide: implement typed tables + generic declared PK types, or narrow the spec to a dynamic store (generic `String`/`Bytes` PK preferred for FablePool-capable) — #255.
- **C6 — EventStore persistence & frozen shapes:** ordinary append is **ETS-only** (`event_store.ex:102-117`); `SqliteBackend.append/1` is never called from `lib/`, never started/migrated at boot, and the durability moduledoc is **false**; restart durability is not genuinely tested. Either wire persistence onto the ordinary append path or correct the docs/STABILITY classification before any "stable" claim.

**Wave D — Dogfood conformance & release gate** *(1.0 blocker, CONTINUOUS — begins in Wave A, stays green thereafter)* — milestone v0.5.0:
- [#262](https://github.com/kormie/Skein/issues/262) — the gate must **compile + load + RUN** reduced, **pinned** conformance programs from Skein examples, `skein-testing`, and `FablePool-skein`. **Today nothing in Skein compiles, loads, or runs either external repo** (verified: no workflow checks them out; every reference is a comment/changelog citation). The gate must assert real `Result`/error/schema/capability/store shapes and **detect API drift** — both external ports still use ambient `Uuid.new()` (`skein-testing/src/main.skein:115`, `FablePool-skein/src/fablepool.skein:991`) rather than capability-gated `uuid.new()`; FablePool stubs canonicalization as a string fingerprint (`fablepool.skein:117-120`) and signatures as opaque tags, and uses the surrogate-Uuid `@primary` + `op_id: String @unique` workaround (#255).
- Compile every fenced `skein` block in the spec and docs site ([#202](https://github.com/kormie/Skein/issues/202) subset; `spec_examples_test.exs` covers §8 only today). Snapshot **complete** structured diagnostics, add runtime effect-shape tests for every method (only `http` is shape-tested today), and add property tests where input spaces are wide. Release-readiness cannot report green without the dogfood jobs.

**Wave E — Conditional minimal canonical substrate** *(conditional 1.0 blocker — only if the FablePool-capable promise is kept)* — milestone v0.6.0, created **only after** the decision issue resolves:
- **Decision required first** (see the FablePool-capable decision issue): keep the promise → 1.0 needs a canonical-encoding spec + cross-impl test vectors, a `Bytes` type, hash primitives, hex/base64, **verify-only** signature primitives via a narrow internal `:crypto` wrapper (**not** general FFI), and generic content-address-friendly store keys ([#256](https://github.com/kormie/Skein/issues/256), [#245](https://github.com/kormie/Skein/issues/245), [#246](https://github.com/kormie/Skein/issues/246), [#250](https://github.com/kormie/Skein/issues/250)). Drop the promise → all of this moves to v1.1 and the train goes v0.5.0 → RC.
- Scope controls: no general FFI; no signing/keygen/custody/secure-RNG in 1.0 ([#257](https://github.com/kormie/Skein/issues/257) is 1.1); no FablePool-specific store/log/provenance/grant/redaction APIs.

**Wave F — Stability freeze, true RC & soak** *(1.0 blocker)* — milestones v1.0.0-rc.2 → v1.0.0:
- Freeze grammar/keywords, diagnostic meanings + fields, effect ABI + error shapes, JSON Schema derivation + vectors, CLI/JSON/config, compiled-metadata classes, EventStore persisted vectors, canonical vectors (if Wave E kept), and the pinned dogfood revisions — only after every preceding contract is executable and green. No feature work in the RC milestone; run the exact GA release-readiness workflow and soak the same candidate.

### Cut from the minimal 1.0 surface (→ 1.1)

"FablePool-capable" was sharpened to "minimal substrate," moving these out of 1.0 (preserved on their issues, retargeted to v1.1):
- [#248](https://github.com/kormie/Skein/issues/248) closures — 1.1 unless the conformance suite (#262) proves them a hard blocker.
- [#257](https://github.com/kormie/Skein/issues/257) effectful crypto (RNG/keygen/signing), [#255](https://github.com/kormie/Skein/issues/255) content-addressed store, [#141](https://github.com/kormie/Skein/issues/141) general FFI (the 1.0 crypto route is the internal `:crypto` wrapper in #245, not `extern`).
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
- [#255](https://github.com/kormie/Skein/issues/255) — content-addressed / non-Uuid-`@primary` store — M
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
