# Design: Scenario-Scoped Capability Environments

**Status:** Accepted direction for 1.0 (2026-06-15 roadmap reset)
**Supersedes:** `docs/design/capability-bound-implementations.md` (the `via &stub` / `via Module`
"capability-bound implementations" plane) — that design is **not** the 1.0 surface.
**Tracking:** the "Scenario capability environments" epic and its work packages (see `docs/ROADMAP.md`,
Wave 2).

## 1. Why this replaces `via`

The prior draft (`capability-bound-implementations.md`) unified effect overrides with capability
declarations via a flat `scenario { capability X via &stub }` list, plus a `via Module` form for
stateful behaviour stubs (§12). The reset rejects that surface for 1.0 because:

1. **`via &stub` is a flat binding, not an environment.** It does not express *which tool execution*
   an override belongs to. A refund scenario that stubs `http.out` is really stubbing the HTTP the
   *tool* makes — the flat list loses that scoping.
2. **`via Module` re-opens a second cross-module seam.** Tools (`tool.call`, E0016) are deliberately
   the *only* cross-module seam. A bare-module binding after `via` (design §12.2 **[FREEZE]**) risks
   becoming a parallel one. Reconsider in 1.1, not 1.0.
3. **`&named_fn` stubs are not local or obviously pure.** A provider should read like the thing it
   replaces, inline, with a typed signature the analyzer checks — not a reference to a helper module.

The keystone idea from the prior design survives: **run a feature under a scoped capability
environment, control outside-world effects, and make missing/uncontrolled effects obvious.** Skein
can do this more strongly than Swift's Dependencies library because capabilities are already part of
the language. We keep the idea, change the surface.

## 2. Target shape

A scenario that tests a tool declares the **complete capability environment** that tool may exercise,
as a nested tree under the tool envelope:

```skein
scenario "refund sends id header" {
  capability tool.use(Billing.Refund) {
    capability http.out("api.stripe.com") {
      implement(req: HttpRequest) -> Result[HttpResponse, HttpError] {
        match Map.get(req.headers, "id") {
          Some(_) -> Ok(HttpResponse { status: 200, headers: {}, body: { ok: true } })
          None    -> Err(HttpError.Provider("missing id header"))
        }
      }
    }

    capability uuid {
      implement() -> Uuid { Uuid.parse("00000000-0000-4000-8000-000000000001")! }
    }

    capability instant {
      implement() -> Instant { Instant.parse("2026-01-01T00:00:00Z")! }
    }
  }

  expect {
    let result = tool.call(Billing.Refund, { ticket_id: "t_123" })!
    assert result.status == "ok"
  }
}
```

## 3. Semantics

During scenario execution:

- `tool.use(Billing.Refund)` is the only tool the scenario authorizes.
- While `Billing.Refund` executes, it may use **only** the capabilities nested under its envelope.
- A nested capability with an `implement` block uses that controlled implementation.
- A nested capability with no `implement` block falls through to the **test-runner default policy**
  (§6).
- An effect with no implementation and no safe test default is **blocked** unless explicitly allowed
  by CLI/config.
- Nested capabilities are scoped to the **tool envelope**, not the whole scenario:
  `http.out("api.stripe.com")` here is available only while `Billing.Refund` runs.

## 4. Rules (1.0)

1. **Production callers are unchanged.** Production code still declares only
   `capability tool.use(Tool.Name)`. The tools-only cross-module seam is preserved.
2. **Scenarios/goldens are stricter than production callers.** They intentionally reveal and control
   the full nondeterministic dependency set of the tool under test.
3. **Nested capabilities are tool-envelope-scoped**, not scenario-global.
4. **`implement` blocks are test-only**, local, typed, and **pure** — no effect calls (directly or
   through helpers); no `tool.call`/`http.*`/`llm.*`/`store.*`/`memory.*`/`uuid.new`/`instant.now`/
   `process.*`/`timer.*`/`event.log` inside a provider block.
5. **No `via` syntax in 1.0.**
6. **No `via Module` in 1.0** (second cross-module seam risk).
7. **No general stateful behaviour stubs in 1.0** (store/memory/event "third read fails" is 1.1).
   1.0 may support **seed-only** state if the conformance suite proves it necessary (open decision —
   §8).
8. The runtime enforces a **dynamic scenario capability stack** (push tool envelope on `tool.call`,
   pop on return; propagate to spawned work).
9. The analyzer computes **tool effect summaries** (transitive) and **rejects** scenarios whose
   envelope does not cover the tool's effects.
10. The test runner supplies **controlled defaults** for nondeterministic effects and **blocks live
    effects** unless explicitly allowed.

## 5. Compiler / runtime work

> **Implementation status (re-baselined 2026-06-19 against source).** The **runtime side is landed and
> contract-met** (verified by the 2026-06-19 audit): the dynamic capability stack with resolution
> order `implement → replay → test-default → live → failure` (`capability_stack.ex`,
> `nondeterminism.ex`, `http.ex`, `llm.ex`), the uncatchable `LiveEffectError` raise for blocked-live
> effects, the Wave-3 `TestPolicy` defaults + live blocking, and `SpawnContext` propagation to
> spawned processes/tasks/timers (#282) — and `Dependencies`/`with_overrides` are retired. Parser/AST
> (#280), effect-summary analysis + E0028 (#281), and test-purity E0029 (#273) also landed.
>
> **Update (2026-07-02, post-Wave-B sanity check):** the above gaps **landed in B6 (#295)** and are
> source-verified — provider `implement` bodies are type-checked against their capability's exact
> provider contract (`@provider_contracts`, E0038) with full `infer_type` + declared-return checking,
> and purity IS transitive (`collect_effect_sites` follows local fn calls and `&fn` references),
> pinned by the `provider_contract_mismatch` / `provider_unsupported_capability` /
> `transitive_effect_in_provider` negative fixtures. **Resolved 2026-07-02 (#279):** `llm.embed` under a scenario
> `model` envelope resolves PAST the chat-shaped `implement` provider (replay → test-default →
> live-blocked), staying deterministic offline — `LlmResponse` is text-only, so an embed provider
> form does not exist; and `given` is reconciled per the signed-off decision below: it stays, as the
> home for seed-only stateful fixtures (spec §3.10 documents evaluation order and scoping).

**Parser / AST.** *(done — #280)* `scenario_item = capability_envelope | given_block | expect_block`.
`AST.Capability` gained `nested` (`[Capability]`) and `implement` (`CapabilityImplement{params,
return_type, body, meta}`); `AST.Scenario` gained `capabilities`. `via` never enters the
lexer/grammar (a `via` after a capability is a structured parse error). Typed provider return values
use nominal record literals `TypeName { ... }`.

**Analyzer.** *(done — #281/#273/#274)*
- **Effect-summary analysis**: per tool, the transitive set of effect calls (direct + through helper
  fns); a scenario whose envelope does not cover a called tool's summary is rejected (E0028).
- Provider/test **purity**: effects are not allowed in `test` bodies or in `implement` providers
  (E0029).
- **Provider contract types**: `HttpRequest`/`HttpResponse`/`LlmRequest`/`LlmResponse` + `Json`.

**Runtime.** *(largely done — #282)* `Skein.Runtime.CapabilityStack` is a dynamic capability-context
stack. The scenario test fn registers its tool envelopes; `tool.call` pushes the matching envelope
(nested under the active tool, else the registered top-level one) and pops on return. Per-effect
resolution order: (1) scenario `implement` provider → (2) replay (golden) → (3) deterministic
test-runner default *(Wave 3)* → (4) live (only if allowed) → (5) structured failure. `uuid`,
`instant`, and `http` resolve through the stack today (via `Skein.Runtime.Nondeterminism` /
`Skein.Runtime.Http`); the process-dict override and `Skein.Runtime.Dependencies` are **retired**.
Propagation to spawned work is **done**: `Skein.Runtime.SpawnContext` captures the capability stack,
the registered scenario envelopes, and the test policy in the spawning (or, for timers, the
scheduling) process and reinstalls them inside the spawned body, so `process.spawn` and `timer` task
bodies resolve effects identically to inline work. (Golden `Replay` is intentionally not propagated —
its recorded-event cursor is consumed on read, so a concurrent copy would double-serve events.)
Remaining: `llm`/`model` routing for `llm.embed`.

## 6. Test-runner default policy

`skein test` is conservative by default:

| Effect | Default scenario policy |
|---|---|
| `uuid` | deterministic incrementing provider |
| `instant` | fixed / stepping provider |
| `llm.*` | deterministic test backend or replay-only |
| `http.*` | **blocked** unless `implement`/replay/explicit live allow |
| `store.*` | scenario-local isolated state |
| `memory.*` | scenario-local isolated state |
| `tool.call` | real tool implementation under its nested envelope |
| `process.spawn` | deterministic/synchronous or blocked until supported |
| `timer.*` | deterministic or blocked until supported |
| `event.log` | scenario-local event log |

Live effects are opt-in and never accidental. The escape hatch is the **repeatable**
`skein test --allow-live <effect>[:<scope>]` flag (#283): `--allow-live http.out:api.stripe.com`
permits exactly that host; a scopeless `--allow-live model` permits every model; only the outbound /
nondeterministic effects are gatable (`http.out`, `model`, `uuid`, `instant`). An unknown effect is a
structured parse error.

The policy is `Skein.Runtime.TestPolicy`, a process-scoped context the `skein test` runner installs
around each scenario/golden. It inserts the **test-default** step into effect resolution
(`implement → replay → test-default → live`): `uuid`/`instant` get deterministic generators
(incrementing UUID from `…001`; instant stepping +1 s from a fixed `2026-01-01T00:00:00Z` base, reset
per test); `http.out`/`model` raise `Skein.Runtime.LiveEffectError` when they would go live unallowed
(a raise, not an `Err`, so a program's own error handling cannot swallow the block); a deterministic
LLM test backend stays allowed with no setup. Scenario-local `store`/`memory`/`event.log` state is
reset before each test so it never leaks. Production (`skein run`, no policy active) is untouched.

Golden bodies are wrapped in the replay context (`core_erlang.ex`), so a replayed test that exhausts
or mismatches its trace is a structured error, never a silent live call.

## 7. Effect provider contracts

`implement` blocks reference named, schema-deriving types. `HttpResponse`/`HttpError`/`LlmError`
exist in the spec (§6, `SKEIN_SPEC.md:580,621`); **`HttpRequest`/`LlmRequest`/`LlmResponse` do not
and must be added.** Per-namespace provider contracts:

| Capability | `implement` signature |
|---|---|
| `uuid` | `implement() -> Uuid` |
| `instant` | `implement() -> Instant` |
| `http.out(host)` | `implement(req: HttpRequest) -> Result[HttpResponse, HttpError]` |
| `model(provider, model)` | `implement(req: LlmRequest) -> Result[LlmResponse, LlmError]` |
| `tool.use(T)` | the tool's own `T.Input -> Result[T.Output, T.Error]` (an alternate `implement`) |

Use Skein `Ok(...)`/`Err(...)` — never ad-hoc Erlang tuple shapes, never magic variables.

## 8. Decisions (signed off 2026-06-15)

- **`implement` block signature/keyword — RESOLVED:** `implement(params) -> ReturnType { body }`,
  reusing the existing `implement` keyword (the one tool bodies already use). No new keyword. A
  capability envelope holds at most one `implement` block.
- **Fate of `given` — RESOLVED:** keep `given`, repurposed as the home for **seed-only stateful
  state** in 1.0 (pre-populated store/memory). Value bindings continue to use plain `let` inside
  `expect`.
- **Seed-only stateful state — RESOLVED:** in 1.0, via `given` (above). General behavioural stateful
  stubs ("third read fails") remain 1.1.
- **Names/shapes of provider contract types — RESOLVED (#274):**
  - `HttpRequest { method: String, url: String, headers: Map[String, String], body: Json }`
  - `HttpResponse { status: Int, body: Map, headers: Map[String, String] }` (existing)
  - `LlmRequest { model: String, system: String, prompt: String }` (minimal)
  - `LlmResponse { text: String }` (minimal; `llm.json` decodes `text` against the target schema)
  - `Json` — a named type for an arbitrary JSON value (object/array/string/number/bool/null).
- **CLI live-effect flag syntax — RESOLVED (#283):** repeatable `--allow-live <effect>[:<scope>]`,
  effect tokens drawn from the capability kinds (`http.out`, `model`, `uuid`, `instant`); scope
  optional (omit to allow all scopes), host-based for `http.out`. A blocked live effect raises
  `Skein.Runtime.LiveEffectError` (fails the test) rather than returning a new `Err` variant.
- **Deterministic test defaults — RESOLVED (#283):** `uuid` increments from
  `00000000-0000-4000-8000-000000000001`; `instant` steps +1 s from `2026-01-01T00:00:00Z`. Counters
  reset per test.

## 9. What moves to 1.1

`via` (if still useful), `via Module`, behavioural stateful stubs ("third read fails"), general
effect-provider interfaces, content-addressed store, append-only/verifiable log, signing/keygen/
secure RNG, provenance/lineage, data-layer grants, closures, general FFI.
