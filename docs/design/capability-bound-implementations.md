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
  capability uuid                                   via &Stubs.incrementing
  capability instant                                via &Stubs.fixed_clock
  capability model("anthropic", "claude-opus-4-8")  via &Stubs.approve_llm
  capability tool.use(Stripe.Refund)                via &Stubs.refund_ok

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

The left is exactly a capability declaration (same grammar as a module's). The right is a
`&`-reference to a named function (always `&named_fn`, never an inline lambda — Skein has
none). The binding keyword is **`via`** (recommended):

```
capability <kind>(<params>) via &<fn or Module.fn>
```

**Syntax decision (CONFIRMED):** `via` over `=` (reads like equality on a capability) and
over `>>=` (rejected: `>>=` is the monad-bind operator, which violates P1's "no operator
overloading / no monadic notation" and hurts agent-writability — a keyword is read/generated
more reliably than a one-off glyph).

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

## 6. Stateful effects: `store`, `memory`, `event` — NEEDS DISCOVERY

A `&fn` stub is the wrong shape for stateful effects (a KV store is not a function). This is
the least-settled part and warrants a **discovery spike** before locking, because it also
has to serve `golden` (see below).

- **(B) Stub module with op-functions — leaning this way.** Bind
  `capability store.table("users") via &Stubs.UsersStore` where the stub exposes
  `get/put/query/delete`. Uniform with §5 (a capability is served by a named implementation),
  at the cost of reintroducing a multi-fn stub module and an interface notion. *Does not
  preclude* seed data — a stub store can be initialized from seed data.
- **(A) Isolated state + seed data only.** `store`/`memory`/`event` get fresh scenario-local
  state seeded via a data block, with no behavioral stub. Simpler, but can't express
  behavior (e.g. "the third read fails").

**Direction:** B is likely right and composes with seed data, but confirm via discovery.

> **Resolved (see §12).** The discovery spike (#275) adopted **B** — refined as a runtime-owned,
> scenario-local *state cell* driven by pure state-transition implementations — with Option A's
> isolation as the zero-config default and a seed `&fn` shortcut for the common case. See §12 for
> the worked examples, the `golden` plan, the `given` verdict, and the interface mechanism.

### `golden` and seed data

`golden` tests replay a recorded trace and assert same-outcomes; they need the same control
over stateful effects (reconstruct store/memory state from the trace or from seed data). So
whatever shape stateful control takes must serve **both** `scenario` (forward stubbing) and
`golden` (trace reconstruction). The discovery spike covers both.

### The fate of `given` — REVISIT

If stateful effects use stub modules (B), the original justification for a `given` *data*
block weakens (seed data can initialize a stub, or be plain `let` bindings). Open question:
does `given` survive as a distinct seed-data construct, fold into stub initialization, or
disappear in favor of `let`? Resolve alongside the stateful-effects spike.

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

## 10. Status of open questions

- **Syntax** — ✅ **confirmed: `via`** (over `=` and the rejected `>>=`).
- **5a** — *direction:* adopt per-namespace request→response stub contracts; finish the
  `HttpRequest`/`LlmRequest`/… spec types. Tracked as workstream (iii).
- **6a — stateful effects + `golden` + the fate of `given`** — ✅ **resolved by the #275 spike
  (§12):** adopt B (runtime-owned scenario-local state cell + pure transition impls), with
  Option A isolation as the default and a seed `&fn` shortcut; `golden` reuses the same cell
  via trace-fold (the *replay* rung); **`given` is removed** (use `let` / seed `&fn`); the
  interface is a compiler-known per-namespace behaviour contract checked E0020-style.
- **8 — test purity** — *direction:* analyzer hard-errors effects inside `test`; stub fns
  must be pure. Tracked as workstream (ii).

## 11. Packaging (decided: split into 3 + discovery)

1. **Capability-bound implementations** — runtime resolution (bound stub → replay → live) +
   `scenario` `capability … via &impl` binding for behavioral effects (uuid/instant/http/
   llm/tool); retire `Dependencies`/`with_overrides`. *Reshapes #267.*
2. **Test purity** — analyzer-enforced: effects only in `scenario`, never `test`; stubs pure.
3. **Stub-contract types** — `HttpRequest`/`HttpResponse`/`LlmRequest`/`LlmResponse`/… as
   schema-deriving spec types (§5a).
4. **Discovery spike** (gates the stateful slice of #1) — stateful effects (store/memory/
   event) under `scenario` *and* `golden`, and the fate of `given` (§6).

## 12. Addendum: stateful effects, `golden`, and the fate of `given` (resolved)

*Outcome of the #275 discovery spike. Supersedes the "NEEDS DISCOVERY" / "REVISIT" notes in
§6 and the open item 6a in §10. This is design; implementation is the stateful slice of #267,
gated on sign-off. Freeze-sensitive calls are flagged **[FREEZE]**.*

### 12.1 The crux: why a `&fn` is the wrong shape, and how purity is preserved

Behavioral effects bind a **pure request→response `&fn`** (§5) because the effect is itself
stateless. `store`/`memory`/`event` are not: `get("k")` must return whatever an earlier
`put("k", v)` wrote *in the same scenario*. Skein functions are pure and hold no mutable
state, so the *implementation* cannot own the state.

Resolution: **the runtime owns a scenario-local *state cell*; the bound implementation is a
pure state transition over it.** This is the exact generalization of §5 — behavioral is the
stateless degenerate case, stateful threads state — and it mirrors how Skein agents already
work (a `gen_statem` whose callbacks are pure functions of `(state, input) -> (state, output)`).
Purity (§8) holds unchanged: no effect call ever appears *inside* a stub.

### 12.2 Shape — adopt **B**, three tiers on one resolution ladder

A capability is served by a named implementation (the §5 principle). For stateful effects the
implementation drives the runtime-owned cell. There are three tiers, and they share the one
`bound → replay → live` ladder of §7:

- **Tier 0 — isolation default (Option A, zero-config).** With no binding, each `scenario`
  gets fresh, isolated `store`/`memory`/`event` state running the *live* op semantics
  (generalizing today's per-test `clear()`). This is the common "I just need a clean slate" case.
- **Tier 1 — seed shortcut (the 90% case).** Bind a pure data constructor:
  `capability store.table("users") via &Fixtures.users` where
  `&Fixtures.users : &fn() -> [User]`. The runtime initializes the cell from the seed and runs
  **default** op semantics over it. Same `&fn` form as behavioral effects — no new concept.
- **Tier 2 — behavioral stub (the rare case, what overturns Option A).** Bind a scenario-local
  **module** that implements the namespace behaviour contract (§12.5) as pure transitions over
  the cell; un-overridden ops fall through to default semantics. This expresses
  "the third read fails," which Option A cannot.

**[FREEZE] New syntax form.** Tier 2 binds a *module*: `via Stubs.FlakyUsers` (bare name, no
`&` — `&` stays exclusively for function references; Skein already passes bare module/type
references in `tool.use(T)`). Tiers 0–1 introduce no new syntax beyond #267's `via &fn`.

#### Worked example — store, seed (Tier 1)

```
module RefundService {
  fn tier_of(id: String) -> String {
    match store.get("users", id) { Ok(u) -> u.tier, Err(_) -> "unknown" }
  }

  scenario "gold users are prioritized" {
    capability store.table("users") via &Fixtures.gold_users
    expect {
      assert tier_of("u1") == "gold"
      assert tier_of("u2") == "silver"
    }
  }
}

module Fixtures {
  fn gold_users() -> [User] {
    [ User { id: "u1", tier: "gold" }, User { id: "u2", tier: "silver" } ]
  }
}
```

#### Worked example — store, behavioral "the third read fails" (Tier 2)

```
scenario "retries on transient store failure" {
  capability store.table("users") via Stubs.FlakyUsers
  expect {
    assert tier_of("u1") == "gold"          -- read 1: ok
    assert tier_of("u1") == "gold"          -- read 2: ok
    assert tier_of("u1") == "unknown"       -- read 3: Err(Unavailable) -> handled
  }
}

module Stubs.FlakyUsers {                     -- implements the `store` behaviour contract
  type S = { rows: Map[String, User], reads: Int }

  fn init() -> S {
    S { rows: { "u1": User { id: "u1", tier: "gold" } }, reads: 0 }
  }

  fn get(s: S, id: String) -> (S, Result[User, StoreError]) {
    let s2 = S { ...s, reads: s.reads + 1 }
    match s2.reads {
      3 -> (s2, Err(StoreError.Unavailable))
      _ -> match Map.get(s.rows, id) {
        Some(u) -> (s2, Ok(u))
        None    -> (s2, Err(StoreError.NotFound))
      }
    }
  }
  -- put / query / delete omitted -> fall through to default isolated semantics
}
```

#### Worked example — memory and event (seed; Tier 2 analogous)

```
scenario "resumes from a prior decision" {
  capability memory("sessions") via &Fixtures.prior_session   -- &fn() -> Map[String, Json]
  expect { assert recall_decision("s1") == "approved" }
}

scenario "summarizes prior audit events" {
  capability event via &Fixtures.prior_events                 -- &fn() -> [Event]
  expect { assert audit_count() == 2 }
}
```

`event` is append-only, so its seed is the list of prior events and the cell is the log
itself; a Tier-2 `event` stub (e.g. failing `event.log`) is possible but expected to be rare.

**Rejected alternatives (recorded for the freeze trail).**
- *Option A alone* — cannot inject failure ("the third read fails"), a stated requirement.
  Retained only as Tier 0 (the default).
- *Single reducer `&fn(state, Op) -> (state, Result)`* over an `Op` sum type — the most
  syntax-conservative form (stays `&fn`-only, extends §5's "one shape covers all verbs"
  literally), but: poor readability (one big `match` over `Get|Put|Query|Delete`), no per-op
  fallthrough to defaults (every op must be handled), and awkward seeding/`init`. The named-op
  module (Tier 2) reads like the real store and lets you override only the op under test.

### 12.3 `golden` plan — the same ladder, with the trace as the binding source

`golden` is **not a separate mechanism**; it is the **replay rung** (§7, rung 2) of the same
ladder, and it drives the **same scenario-local state cell** as `scenario`. The only
difference is where the cell's contents come from:

- **Behavioral effects** → recorded responses via `Replay.next_response(kind, expected)`
  (already implemented; validates the live call against the recording).
- **Stateful effects** → the cell is seeded by **folding the recorded mutation events** from
  the trace, then live ops run against it:
  - `memory` already records a `:state_change` event per mutation and reconstructs via
    `memory.rebuild_from_events/1` / `Replay.rebuild_memory/2` — reuse as-is.
  - **`store` is the one gap:** today it emits only `:store` trace *spans*, not reconstructable
    mutation events. The stateful slice of #267 must give `store` put/delete the same
    event-sourced reconstruction parity memory has (emit fold-able mutation events; extend the
    rebuild to cover `store`).
  - `event` needs no reconstruction — the recorded log *is* the state.

So: `scenario` binds the cell at rung 1; `golden` folds the trace into it at rung 2; production
is live at rung 3. `bound → replay → live` is unchanged. Conceptually, **a `golden` test is a
`scenario` whose seed/behavior is supplied by a recorded trace instead of a stub.**

### 12.4 The fate of `given` — **removed** **[FREEZE]**

`given` has no remaining unique role and is **removed**:

- Plain value bindings (today's §8.5 `given { ticket_id: "abc-123" }`) are semantically
  identical to `let ticket_id = "abc-123"` in the scenario body — keeping both violates P1
  ("one obvious way").
- Stateful *seed* data now lives in a seed `&fn` (Tier 1) or a stub `init` (Tier 2), not a
  separate data block.

**Migration surface (implementation, post-sign-off):** drop `given_block` from the grammar
(spec §3.10), so `scenario` body becomes `capability`-bindings + `let`s + `expect`; update the
§8.5 example to use `let`; sweep `examples/` and the test fixtures
(`spec_examples_test.exs`, `test_construct_test.exs`) for `given {`. The parser/AST/analyzer/
codegen paths that currently handle `given_vars` (`parser.ex:852`, `analyzer.ex:1654`,
`core_erlang.ex:1370`) are removed or folded into ordinary `let` handling.

### 12.5 Interface mechanism — behaviour contract, not a cross-module call (answers Q4 / E0016)

A Tier-2 stub is a **scenario-local module implementing a compiler-known behaviour contract**,
one per stateful namespace — the direct analog of a tool's `implement` over its contract:

| Namespace | Behaviour contract (pure transitions over the cell `S`) |
|---|---|
| `store.table(T)` | `init() -> S`, `get(S, id) -> (S, Result[Rec, StoreError])`, `put(S, Rec) -> (S, Rec)`, `query(S, Filter) -> (S, [Rec])`, `delete(S, id) -> (S, Result[Id, StoreError])` |
| `memory(ns)` | `init() -> S`, `get(S, key) -> (S, Result[V, _])`, `put(S, key, V) -> (S, V)`, `delete(S, key) -> (S, _)`, `list(S) -> (S, [key])` |
| `event` | `init() -> S` (prior events), `log(S, name, data) -> (S, _)` |

- The analyzer checks the binding against the contract **E0020-style** (the same mismatch class
  §5 uses for behavioral `&fn`s) — **not E0016**.
- **E0016 is structurally untouched.** It fires only on *call expressions* (`Mod.fn(...)`,
  qualified self- or cross-module). User code still writes `store.get(...)` — an effect routed
  by the runtime — and **never** writes `Stubs.FlakyUsers.get(...)`. The binding `via
  Stubs.FlakyUsers` is a *reference* (data on the capability), not a call site. The runtime
  owns the cell and invokes the stub's pure transitions to advance it, exactly as it invokes
  the live store — just bound.
- Un-overridden ops fall through to default semantics (the contract has default
  implementations = the live in-memory store/memory/event ops over the cell).

### 12.6 Impact on #267 scope

The spike unblocks #267's stateful slice with a concrete shape and adds these sub-tasks:
1. `via Module` syntax (bare module after `via`) + per-namespace behaviour contracts +
   E0020-style checking of Tier-2 stubs (parser/analyzer).
2. Runtime scenario-local **state cell** with `bound → replay → live` resolution for
   `store`/`memory`/`event`; seed `&fn` (Tier 1) and stub-module (Tier 2) drivers.
3. **`store` mutation events for `golden` reconstruction** — parity with `memory`'s
   `:state_change` / `rebuild_from_events`.
4. **Remove `given`** — grammar/spec/examples/tests migration (§12.4).
