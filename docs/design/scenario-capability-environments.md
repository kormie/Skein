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

**Parser / AST.** `scenario_item = capability_envelope | let | expect_block`. A `Capability` node
gains an optional nested body (`[capability]`) and an optional `CapabilityImplement { params,
return_type, body, meta }`. Today the scenario AST is flat (`AST.Scenario{description, given_vars,
expect_body}`, `ast.ex:183-194`) and `AST.Capability{kind, params}` has no body (`ast.ex:30-40`) —
both grow. `via` never enters the lexer/grammar.

**Analyzer.**
- **Effect-summary analysis**: for each tool/function, collect direct + transitive effect calls
  (today only local call-site E0012 checks exist, `analyzer.ex:3384-3411`; no transitive summary).
- For each scenario: require a `tool.use(T)` envelope per called tool; require the envelope to cover
  the tool's effect summary; type-check each `implement` block against the effect's provider contract
  (§7); enforce provider **purity**.

**Runtime.** A dynamic capability-context stack (today there is only a flat module capability set +
process-dict `uuid`/`instant` overrides + a replay context — `dependencies.ex:37-92`, no stack).
Resolution order per effect: (1) scenario `implement` block → (2) replay (golden) → (3) deterministic
test-runner default → (4) live (only if allowed) → (5) structured failure. Context propagates to
spawned processes/tasks/timers.

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

Live effects are opt-in and never accidental, e.g. `skein test --allow-live http.out:api.stripe.com`
(exact flag syntax is an open decision — §8). Today there is **no** live-effect blocking and **no**
`--allow-live` flag (`skein_cli.ex:689-738`), and golden bodies are not wrapped in replay
(`core_erlang.ex:1384-1415`) — both are 1.0 gaps.

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

### Still open

- **CLI live-effect flag syntax** (`--allow-live <effect>:<scope>`) — Wave 3.

## 9. What moves to 1.1

`via` (if still useful), `via Module`, behavioural stateful stubs ("third read fails"), general
effect-provider interfaces, content-addressed store, append-only/verifiable log, signing/keygen/
secure RNG, provenance/lineage, data-layer grants, closures, general FFI.
