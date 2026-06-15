# Skein Roadmap

**As of:** 2026-06-15 (roadmap reset)
**Based on:** the prior `/release-readiness` passes (2026-06-11/12), a source-verified dogfooding audit (2026-06-14/15) of the `skein-testing` and [FablePool](https://github.com/kormie/FablePool-skein) ports, **and a first-principles roadmap reset (2026-06-15)** that re-sequenced the path to 1.0 around a smaller, stronger first stable release and replaced the `via` effect-override design with **scenario-scoped capability environments**.

This is the forward-looking work list for Skein. Items are ordered by impact — the top items close the biggest gaps between the language's stated goals and its current reality.

## Release posture (reset 2026-06-15)

**v1.0.0 GA is not imminent, and the next release is not another RC.** v1.0.0-rc.1 was tagged prematurely; the dogfooding audit reclassified GA from a docs-accuracy cleanup to a soundness + honesty + observability + conformance gate. The release train is now driven by two **pre-1.0 development milestones**, then a true RC, then GA:

| Milestone | Carries | Status |
|---|---|---|
| **v0.4.0 — Soundness & scenario capability environments** | Waves 0–2 | active |
| **v0.5.0 — Observability, canonical substrate & conformance** | Waves 3–6 | next |
| **v1.0.0-rc.2 — True release candidate** | cut only when all blockers are green | gated |
| **v1.0.0 Release** | GA after rc.2 soaks | gated |

Milestones live in `.github/milestones.json` (synced by `.github/workflows/milestones.yml`). Note: `mix.exs` is at `1.0.0-rc.4` — a holdover from the pre-reset RC race; the next tag should be `0.4.0`.

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

Most of the foundational gap-closing work from earlier roadmap revisions is **done**: real type inference for field access and pattern bindings, schema derivation for nested types and enum variants, the production Anthropic LLM backend, runtime capability enforcement for tool/LLM/topic (name- and model-aware), agent instance-scoped memory, error `context` + `fix_code` on all compiler errors, float-aware division, multi-`emit` accumulation, tool input validation, contextual (non-reserved) keywords, the persistent SQLite EventStore backend, string-literal match patterns, `store.<table>.get!/put!`, and the `queue.consume`/`schedule.trigger` capability naming.

**That is not the whole picture, and the GA bar moved because of it.** The `/release-readiness` passes only ever swept the *first-party* spec, docs, and §8 examples — never the dogfooding testbeds, which is the entire point of `skein-testing` and FablePool. A source-verified audit of those ports (2026-06-14/15) surfaced ~27 live findings the sweeps structurally could not catch:

- **Soundness holes** — well-typed programs that crash or silently miscompute: effect calls are typed as their bare success type, so a missing `!`/`?` compiles then crashes ([skein-testing#1](https://github.com/kormie/skein-testing/issues/1)); `String + String` type-checks and crashes at runtime ([#252](https://github.com/kormie/Skein/issues/252)); `List.reduce` invoked its callback in the reverse argument order from its own spec ([#254](https://github.com/kormie/Skein/issues/254)); `!`-on-`Option` slips through `test` blocks ([#253](https://github.com/kormie/Skein/issues/253)); unknown effect methods leak `unbound_var`/`:if_clause` ([skein-testing#33](https://github.com/kormie/skein-testing/issues/33)).
- **Spec lies** — the spec's own §8.2 example uses an `Err(NotFound)` pattern that can never match ([skein-testing#3](https://github.com/kormie/skein-testing/issues/3)); `req.json[T]` is documented to validate `@min`/`@max`/`@one_of` but does not ([skein-testing#25](https://github.com/kormie/skein-testing/issues/25)); `resume` and the `timer` callback are documented but unreachable ([skein-testing#20](https://github.com/kormie/skein-testing/issues/20), [#18](https://github.com/kormie/skein-testing/issues/18)).
- **Missing capabilities** — porting a real signed/content-addressed protocol hit a wall: no closures ([#248](https://github.com/kormie/Skein/issues/248)), no crypto/bytes/encoding ([#245](https://github.com/kormie/Skein/issues/245)), no `Int` modulo/bitwise ([#246](https://github.com/kormie/Skein/issues/246)), no `String.join`/codepoints ([#250](https://github.com/kormie/Skein/issues/250)), no record update ([#251](https://github.com/kormie/Skein/issues/251)) or module constants ([#249](https://github.com/kormie/Skein/issues/249)).

Under the `docs/STABILITY.md` freeze, tagging 1.0 with these in place would make every one a permanent foot-gun. **GA is not imminent.** The six waves below are the path; the GA bar is now a **sound, honest, FablePool-capable core** (decided 2026-06-15).

---

## Path to v1.0.0 — the six waves

Ordered; earlier waves unblock later ones. TDD + property tests mandatory. Each wave maps to a milestone (v0.4.0 = Waves 0–2; v0.5.0 = Waves 3–6). Every 1.0 blocker must have a test/gate defined before it is considered done.

**Wave 0 — Release posture & docs truth** *(1.0 blocker)* — milestone v0.4.0:
- Stop RC-promotion framing across `docs/ROADMAP.md`, the docs-site roadmap, `docs/STABILITY.md`, `CONTRIBUTING.md`. No page may claim v1.0.0 GA is imminent or describe `via` as accepted 1.0 design.
- `docs/SKEIN_SPEC.md`: remove the unqualified "v1.0 frozen" claim; flag the scenario-testing surface (§3.10/§8.5), `given`, `resume`, `uuid`/`instant` as in-flux. Capability list in the spec must match implementation.
- `docs/ARCHITECTURE.md`: document the scenario-scoped capability environment model.

**Wave 1 — Type/runtime soundness** *(1.0 blocker — mostly complete)*:
- ~~[#259](https://github.com/kormie/Skein/issues/259)~~/~~[#260](https://github.com/kormie/Skein/issues/260)~~/~~[#253](https://github.com/kormie/Skein/issues/253)~~ — **done:** the type lattice is sound; effects infer `Result[T,E]`; full inference runs on all executable bodies (test/scenario/golden/tool-`implement`/agent handlers). Symptoms cleared: ~~[#252](https://github.com/kormie/Skein/issues/252)~~, ~~[skein-testing#33](https://github.com/kormie/skein-testing/issues/33)~~, ~~[#254](https://github.com/kormie/Skein/issues/254)~~.
- **Remaining (blocker):** a **negative-fixture corpus** that catches every known dogfood soundness failure (the 15 fixtures under `apps/skein_compiler/test/skein/conformance/negative/` are the seed — extend to cover `:unknown` at public boundaries, record/map structural checks, effect-shape mismatches). **Golden replay activation** — golden bodies load a trace but are not wrapped in a replay context (`core_erlang.ex:1384-1415`), so they can silently hit live effects; make golden bodies actually intercept effects. Tool **output** schema enforcement (input is checked; output is not).

**Wave 2 — Scenario-scoped capability environments** *(1.0 blocker, freeze-sensitive)* — design: [`scenario-capability-environments.md`](design/scenario-capability-environments.md). Replaces the `via` design (#267 superseded). Work packages (sharp issues):
- Parser/AST for nested scenario capability envelopes + `implement` blocks (today the scenario AST is flat — `ast.ex:183-194`; `Capability` has no body — `ast.ex:30-40`).
- Tool **effect-summary** analysis (direct + transitive; today only local E0012 checks exist — `analyzer.ex:3384-3411`).
- Provider **purity** checking for `implement` blocks (companion to test purity [#273](https://github.com/kormie/Skein/issues/273)).
- Effect **provider contract types** [#274](https://github.com/kormie/Skein/issues/274) — add `HttpRequest`/`LlmRequest`/`LlmResponse` (only `HttpResponse`/`HttpError`/`LlmError` exist today, `SKEIN_SPEC.md:580,621`).
- Runtime **dynamic capability stack** (today: flat module set + process-dict uuid/instant overrides + replay — `dependencies.ex:37-92`; no stack). Resolution: `implement → replay → test-default → live → structured failure`. Retire `Skein.Runtime.Dependencies`/`with_overrides`.
- Analyzer-enforced **test purity** [#273](https://github.com/kormie/Skein/issues/273): effects only in `scenario`, never `test`. [#268](https://github.com/kormie/Skein/issues/268) — pre-freeze `!`/`?` polish.

**Wave 3 — Deterministic scenario/golden/replay gate** *(1.0 blocker)* — milestone v0.5.0:
- Scenario-local store/memory/event isolation; controlled uuid/instant providers; llm test-backend/replay; `http` blocked unless implemented/replayed/explicitly allowed; structured mismatch/exhausted diagnostics; JSON/plain CLI reporting of scenario failures. Acceptance: offline tests never hit live HTTP/LLM unless explicitly allowed; replayed tests never silently fall back to live; scenario state does not leak between tests.

**Wave 4 — CLI observability & agent contract** *(1.0 blocker)*:
- **Split [PR #239](https://github.com/kormie/Skein/pull/239):** land the framework-neutral pieces first — pure `Skein.CLI.Render` (fix the `skein trace` crash: `main.ex:149` reads `span.name`/`span.duration_ms`, spans carry `:kind`/`:duration_us` — `trace.ex:11-18`), byte-stable plain output, golden trace tests. Then a TTY/TUI seam (`--interactive` opt-in, `--no-tui`/`SKEIN_NO_TUI` force plain; MCP/LSP/non-TTY never route through TUI). JSON output schemas for check/test/trace. The **Raxol TUI** ([#171](https://github.com/kormie/Skein/issues/171)) is **separately gated** — 1.1/1.2 unless it passes the size/cold-start/no-NIF/teardown gates.

**Wave 5 — Minimal canonical substrate** *(1.0 blocker iff "FablePool-capable" stays in the pitch — open decision)*:
- [#256](https://github.com/kormie/Skein/issues/256) — **spec the canonical encoding first** (field/map order, enum/`Option`/`Result`, float policy, domain separation) + cross-impl **test vectors**, then implement.
- [#245](https://github.com/kormie/Skein/issues/245) — pure `Bytes`/hash/hex/base64/**verify-only** crypto via an internal capability-gated `:crypto` wrapper — **not** general FFI.
- [#246](https://github.com/kormie/Skein/issues/246), [#250](https://github.com/kormie/Skein/issues/250) — `Int` modulo/div/bitwise; `String.join`/codepoints (only if conformance needs them).
- **Deferred to 1.1:** signing/keygen, secure RNG beyond UUID ([#257](https://github.com/kormie/Skein/issues/257)), content-addressed store ([#255](https://github.com/kormie/Skein/issues/255)), append-only/verifiable log, provenance/lineage/`why`, grants, redaction policy. No app-specific memory/provenance policy in language core.

**Wave 6 — Dogfood conformance & release gate** *(1.0 blocker)*:
- [#262](https://github.com/kormie/Skein/issues/262) — the gate must **compile + load + RUN** reduced conformance programs from Skein examples, skein-testing, and FablePool-skein (assert real `Result`/error shapes) — today only first-party examples execute (`examples_test.exs`) and the negative corpus is **compile-only** (`negative_corpus_test.exs:51`). Negative tests assert structured diagnostics; runtime effect-shape tests (only `http` is shape-tested today, `http_test.exs:100-155`); docs/spec drift checks [#202](https://github.com/kormie/Skein/issues/202) (compile every fenced `skein` block; `spec_examples_test.exs` covers §8 only); canonical vector tests if Wave 5 is included. Dogfood failures become regression fixtures.

### Cut from the minimal 1.0 surface (→ 1.1)

"FablePool-capable" was sharpened to "minimal substrate," moving these out of 1.0 (preserved on their issues, retargeted to v1.1):
- [#248](https://github.com/kormie/Skein/issues/248) closures — 1.1 unless the conformance suite (#262) proves them a hard blocker.
- [#257](https://github.com/kormie/Skein/issues/257) effectful crypto (RNG/keygen/signing), [#255](https://github.com/kormie/Skein/issues/255) content-addressed store, [#141](https://github.com/kormie/Skein/issues/141) general FFI (the 1.0 crypto route is the internal `:crypto` wrapper in #245, not `extern`).
- Language ergonomics from dogfooding: [#251](https://github.com/kormie/Skein/issues/251) record update, [#249](https://github.com/kormie/Skein/issues/249) module constants, [#247](https://github.com/kormie/Skein/issues/247) enum variant payloads — 1.1 unless conformance proves one a hard blocker.
- `via` / `via Module` / behavioural stateful stubs (the superseded design) — reconsider in 1.1 only if still useful after scenario environments ship.

### Already shipped under the v1.0.0 Release milestone (rc-soak PR)

These items already shipped (the milestone shows 31 closed) — the rc-soak audit + docs-accuracy + Bedrock-hardening wave, **not** the GA gate (the GA gate is the six waves above). The compiler/examples items shipped on the rc-soak audit PR; the
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
- [#202](https://github.com/kormie/Skein/issues/202) — Docs/spec drift guard (the broader registry/generation work; the *compile-every-fenced-block* subset is pulled into Wave 6) — L
- [#240](https://github.com/kormie/Skein/issues/240) — LSP rename + find-references + workspace symbol search — L

### Milestone: v1.2 — Interop & Agent Workflows

Bigger design efforts, after the hardening wave:

- [#141](https://github.com/kormie/Skein/issues/141) — Erlang/Elixir FFI (`extern` keyword) — interop with existing BEAM libraries — XL
- [#144](https://github.com/kormie/Skein/issues/144) — Human-in-the-loop approval workflows — `suspend` before sensitive tool calls — XL
- [#143](https://github.com/kormie/Skein/issues/143) — Web trace viewer — browser-based exploration of trace data — L–XL
- [#171](https://github.com/kormie/Skein/issues/171) — Raxol CLI TUI — the interactive terminal UI, **separately gated** from the framework-neutral CLI render/JSON work pulled into Wave 4 (size/cold-start/no-NIF/teardown gates per PR #239) — XL
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
