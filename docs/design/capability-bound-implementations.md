# Design: Capability-Bound Implementations (the override plane)

**Status:** Draft for sign-off · **Supersedes:** #267 (override unification), the `Skein.Runtime.Dependencies` / `with_overrides` plane merged in #261
**Related:** new "test purity" rule (see §8)

## 1. Summary

An effect override is not a new concept ("dependency") — it is **a capability with its
implementation bound**. A `capability` already declares *permission* to perform an effect;
the only missing half is *which implementation* serves it. In production that is the live
runtime default. A `scenario` may rebind it to a stub:

```
scenario "high-value refund auto-approves" {
  capability uuid                                   = &Stubs.incrementing
  capability instant                                = &Stubs.fixed_clock
  capability model("anthropic", "claude-opus-4-8")  = &Stubs.approve_llm
  capability tool.use(Stripe.Refund)                = &Stubs.refund_ok

  expect { ... }
}
```

This collapses the entire override plane into the capability system. There is no
`Dependencies` module, no `with_overrides`, no `given`-for-effects, and the word
"dependency" never enters Skein's vocabulary. It is swift-dependencies' model with the
**capability as the dependency key Skein already has**.

## 2. Why this over a standalone override API

1. **Capabilities already thread to the runtime.** Every effect call already receives the
   capability set for its compile-time *and* runtime check. Add an optional bound impl to a
   capability and the existing dispatch becomes: *impl present → call it; else live (or
   replay).* No parallel mechanism.
2. **Propagation is free.** Capabilities already flow to spawned agents/tasks, so a bound
   impl rides the same path — satisfying the "propagate to spawned processes" requirement
   without new plumbing.
3. **It finishes the "constitution" idea** (first principles §5.1): "here is the capability,
   and here is its test implementation."
4. **One obvious way (P1).** Reuses an existing construct instead of adding a synonym.

## 3. The model

A capability has two parts: **permission** (what + scope) and **implementation**.

| Context | Implementation |
|---|---|
| Module/handler/agent declaration | the live runtime default (or replay, if a trace is active) |
| `scenario` binding `= &impl` | the named stub, for the duration of that scenario |

Binding never widens permission — `capability http.out("api.stripe.com") = &Stubs.x` still
only authorizes that host. It only swaps *who answers*.

## 4. Syntax

The left of `=` is exactly a capability declaration (same grammar as a module's). The right
is a `&`-reference to a named function (per the answer: always `&named_fn`, never an inline
lambda — Skein has none).

```
capability <kind>(<params>) = &<fn or Module.fn>
```

Stubs are ordinary named functions, naturally grouped in test helper modules (`Stubs.*`).
Because the reference is `&named_fn`, stubs are reusable, inspectable, and themselves pure
(see §8).

## 5. Stub contracts (the substantive question)

Each effect **namespace** defines one stub signature the bound function must match. The
analyzer checks the `&fn` against it (a typed contract, E0020-style on mismatch).

| Capability | Effect ops | Stub contract |
|---|---|---|
| `uuid` | `uuid.new()` | `&fn() -> Uuid` |
| `instant` | `instant.now()` | `&fn() -> Instant` |
| `http.out(host)` | `http.get/post/put/patch/delete` | `&fn(req: HttpRequest) -> Result[HttpResponse, HttpError]` |
| `model(provider, model)` | `llm.chat/json/stream/embed` | `&fn(req: LlmRequest) -> Result[LlmResponse, LlmError]` |
| `tool.use(T)` | `tool.call(T, input)` | `&fn(input: T.Input) -> Result[T.Output, T.Error]` (the tool's own contract) |

The unifying idea: every multi-method namespace already has (or can have) a **single
request→response shape**, so one `&fn` covers all of its verbs. `tool.use(T)` is the
cleanest case — the stub is exactly the tool's declared `input → output` contract, i.e. an
alternate `implement`.

**Open item (5a):** `HttpRequest`/`HttpResponse`/`LlmRequest`/`LlmResponse` need to be
named, schema-deriving types in the spec for the stub signatures to reference. Some exist
partially today; this design requires finishing them. Bounded, but it is spec surface.

## 6. Stateful effects: `store`, `memory`, `event`

A `&fn` stub is the wrong shape for stateful effects (a KV store is not a function). Two
options:

- **(A) Isolated state + data seeding.** In a `scenario`, `store`/`memory`/`event` are
  backed by fresh, scenario-local state, optionally **seeded with data** — and *this* is the
  surviving role of a `given` (data) block:
  ```
  scenario "..." {
    given {
      store.users: [ { id: "u1", email: "a@b.c", name: "Alice" } ]
    }
    capability model(...) = &Stubs.llm
    expect { ... }
  }
  ```
  Behavioral effects → `capability = &fn`. Stateful effects → `given` seed data. Distinct
  shapes, distinct roles.
- **(B) Stub module with op-functions.** Bind `capability store.table("users") = &Stubs.store`
  and require the stub to expose `get/put/query/delete`. More uniform with §5 but reintroduces
  multi-fn modules and an interface notion.

**Recommendation:** (A). It gives `given` a real, non-overlapping job (seed stateful data)
and keeps `capability = &fn` for behavior. **Open item (6a):** confirm (A) vs (B).

## 7. Runtime dispatch & precedence

When an effect is called, the runtime resolves the matching capability and picks an
implementation in this order:

1. **Bound stub** (scenario `= &impl`) — explicit wins.
2. **Replay** (a recorded trace is active) — recorded value.
3. **Live** default.

This generalizes exactly what `uuid`/`instant` do today (override → replay → live), but
keyed off the capability rather than a process-dictionary side-channel.

## 8. Test purity (new pre-freeze rule)

Per the decision that **`test` is pure unit testing and must never carry effectful code**,
while **`scenario` tests cross-module/effectful behavior**:

- The analyzer rejects any **effect call** (any capability-gated effect, including
  `uuid.new()`/`instant.now()`) inside a `test` body — new error, e.g. `E00xx: effects are
  not allowed in a 'test'; use a 'scenario'`. Stubs themselves must be pure too.
- `scenario` is where capabilities (live or bound) and effects live.
- Consequence: there is nothing to override in a `test`, which is *why* the binding surface
  lives only in `scenario`.

This makes "effects are visible/controlled" structural, and it is independently shippable.

## 9. Migration

- The `uuid.new()`/`instant.now()` **effects** (from #261) stay exactly as-is.
- `Skein.Runtime.Dependencies` + `with_overrides` (merged in #261) **retire**: their job
  moves into capability resolution. The capability struct gains an optional `impl`; the
  effect runtimes consult it. The runtime's own ExUnit tests bind impls through the same
  capability set they already pass in (no special API).
- `Llm.set_backend` (global `persistent_term`), the `tool` ETS registry, and ad-hoc ETS
  seeding are removed in favor of capability binding + `given` seed data (the "full replace"
  decision).

## 10. Open questions for sign-off

- **5a** — Adopt the per-namespace request→response stub contracts (and finish the
  `HttpRequest`/`LlmRequest`/… types in the spec)?
- **6a** — Stateful effects via isolated state + `given` seed data (A), or stub modules (B)?
- **8** — Confirm the analyzer hard-errors effects inside `test` (vs warning), and that
  stub fns are required pure.
- **Naming** — `capability X = &impl` with `=`, or a clearer verb (`capability X via &impl`)?
- **Scope of this PR vs splits** — one issue, or split: (i) capability-bound impls +
  runtime, (ii) test-purity rule, (iii) the §5a stub-contract types.
