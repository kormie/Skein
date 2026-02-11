# Skein Language Audit: First Principles vs. Reality

**Date:** 2026-02-11
**Scope:** Full codebase audit against `docs/skein_first_principles.md` and `docs/SKEIN_SPEC.md`

---

## Executive Summary

Skein is a genuinely impressive prototype. The compilation pipeline works end-to-end (`.skein` -> tokens -> AST -> Core Erlang -> BEAM bytecode -> callable function). The runtime is substantial and real. The tooling (CLI, LSP, docs site) is not vaporware. 1,176 tests and 182 property tests provide solid coverage.

But there are serious gaps between the language as described in the first principles document and the language as it actually exists. The type system -- positioned as the keystone of the entire design ("Types Are Contracts", P3) -- is the most significant shortfall: it's a shallow validation pass that degrades to `:unknown` for most real-world expressions. Several foundational syntax features from the spec (object literals, named arguments, tuple destructuring) are simply missing, which means the spec's own canonical examples cannot compile. And the "defense-in-depth" runtime capability enforcement has holes wide enough to drive a truck through.

What follows is organized by first principle, ranked by severity of deviation.

---

## P3: Types Are Contracts -- GRADE: D

> "The type system serves triple duty: it catches bugs at compile time, it generates schemas for LLM tool calling and HTTP APIs, and it provides structured specifications that constrain agent-generated code."

This is the most important broken promise. The first principles document positions types as the *interface language between human intent and machine execution*. In practice, the type system is a thin validation veneer.

### What Works

- Literal type inference: `42` -> `:int`, `"hello"` -> `:string`, `true` -> `:bool`
- Arithmetic operator checking: `1 + "hello"` is caught
- `!` on non-Result produces E0022, `?` on non-Result produces E0023
- Function arity checking against declared signatures
- Stdlib argument type checking (e.g., `String.length(42)` is caught)
- JSON Schema derivation for flat types with built-in primitives
- Constraint annotations (`@min`, `@max`, `@one_of`) flow to generated schemas

### What Doesn't Work

**Field access always returns `:unknown`** (`analyzer.ex`):

```elixir
defp infer_type(%AST.FieldAccess{}, _env) do
  {:unknown, []}
end
```

This single line undermines the entire type system. `record.field` is the most common expression pattern in Skein code, and it is *never* type-checked. `user.email + 42` compiles without error because `user.email` infers to `:unknown`, and `:unknown` is compatible with everything.

**Pattern variable bindings are always `:unknown`:**

```elixir
defp bind_pattern(%AST.Identifier{name: name}, env) do
  %{env | variables: Map.put(env.variables, name, :unknown)}
end
```

After a `match Ok(value) -> ...`, the variable `value` has type `:unknown`. The entire point of pattern matching on `Result` -- to extract a typed value -- is lost.

**User-defined types are opaque to the checker.** A `{:user_type, "Order"}` is compatible with everything. The analyzer stores `TypeDecl` nodes in the environment but never looks up field types from them. Types exist for schema generation only -- they provide zero compile-time safety for code that *uses* those types.

**No generic type propagation.** `List.map(users, &get_name)` returns `:unknown` because the stdlib registry uses `:unknown` for generic type parameters. The type checker cannot propagate element types through higher-order functions.

**FnRef, Call (to unknown targets), and most complex expressions all return `:unknown`.**

### The Real Impact

The first principles document (Section 10.4) claims:

> "This dramatically reduces the surface area of 'things an LLM can get wrong.'"

In reality, approximately 60-70% of expressions in typical Skein code infer to `:unknown` and pass all checks. An LLM generating code gets almost no feedback from the type checker beyond arity errors and obvious literal mismatches. The "Types Are Contracts" principle is aspirational, not actual.

### Schema Derivation Gaps

Schema generation works for flat types but breaks down for composition:

- **User type references are not resolved.** `type Order { customer: Customer }` generates `{"type": "object"}` for the `customer` field instead of inlining `Customer`'s schema. This means LLM tool-calling manifests with nested types will have unconstrained object fields.
- **Data-carrying enum variants are lost.** `enum Event { Charge(amount: Int) }` generates `{"enum": ["Charge"]}` -- the field information is dropped.
- **`Map[K, V]` loses type parameters.** `Map[String, Int]` becomes `{"type": "object"}` with no `additionalProperties` constraint.
- **`Result[T, E]` has no schema mapping** and falls through to a generic object.

---

## P1: One Obvious Way -- GRADE: B-

> "For any given task, there should be exactly one idiomatic way to express it. No synonyms, no sugar, no 'equivalent alternatives.'"

### What's Right

The big decisions here are well-executed:
- **No `if/else`** -- `match` with `true`/`false` is the only conditional. Consistently enforced.
- **No anonymous lambdas** -- functions must be named, references use `&name`.
- **No `return` keyword** -- last expression is the value.
- **No exceptions/try/catch** -- `Result` + crash, period.
- **Braces always** -- no significant whitespace ambiguity.
- **`--` comments only** -- no block comment alternative.

### Where It Breaks Down

**Keyword count has drifted.** The first principles claim "~25 keywords total" (Section 10.1). The actual count is **38** (37 spec + `idempotent`). Many are contextual (`input`, `output`, `errors`, `policy`, `description`, `state`, `strategy`, `child`, `replay`, `given`, `expect`, `assert`, `idempotent`) but all are unconditionally reserved in the lexer. You cannot use `input` as a variable name *anywhere* in a Skein program, even though it's only meaningful inside tool blocks. This violates the "small keyword set" claim and creates a usability trap: `input` is a natural parameter name that will silently fail.

**`assert` desugars in the parser.** CLAUDE.md explicitly states "no desugaring in the parser; that happens in the analyzer." But `assert expr` is transformed into a `%AST.Call{target: "__assert__"}` synthetic call in the parser rather than having its own `AST.Assert` node. Minor, but it's a broken internal rule.

**The universal pattern is not actually universal.** The first principles (Section 3.1) claim every construct follows `<keyword> <name> <signature>? <block>`. In practice:
- `capability` has no name and no block: `capability http.out("api.stripe.com")`
- `handler` has a compound identity (source + method + route), not a single name
- `let` uses `=` instead of a block
- `match` takes an expression subject, not a name

These are reasonable deviations, but the document oversells the regularity.

---

## P4: Effects Are Visible -- GRADE: B

> "Every side effect is declared, traced, and replayable. There is no way to 'sneak' an effect past the capability system."

### Compile-Time: Solid

Capability checking at compile time is the **strongest part of the analyzer**. Every effect call is walked via `collect_effect_calls/2`, mapped to its required capability kind, and checked against declared capabilities. Missing capabilities produce E0012 errors with `fix_hint` and `fix_code`. This genuinely works.

### Runtime: Swiss Cheese

The first principles (Section 5.4) promise defense-in-depth: "Even if a bug bypasses compile-time checks, the runtime blocks unauthorized effects."

Reality:

| Subsystem | Runtime Capability Enforcement |
|-----------|-------------------------------|
| HTTP | Host-level URL check -- **real** |
| Memory | Namespace check -- **real** |
| Store | Table name check -- **real** |
| Tool | Presence-only -- checks *any* `tool.use` exists, **not** the specific tool name |
| LLM | Presence-only -- checks `model` exists, ignores provider/model params entirely |
| Topic | **None** -- `_capabilities` argument is ignored |
| Process | **None** -- `_capabilities` argument is ignored |
| Timer | **None** -- `_capabilities` argument is ignored |
| EventStore | **None** -- `_capabilities` argument is ignored |

The LLM gap is particularly bad: you can declare `capability model("anthropic", "claude-sonnet-4-5")` and call `llm.chat("openai", "gpt-4", ...)` at runtime without error. The runtime accepts the capabilities list and then doesn't inspect it. Four out of nine effect subsystems have *zero* runtime enforcement.

### Replay: Not Real

The first principles (Section 9.3) describe three replay modes: recorded (deterministic), live (re-execute), and hybrid. **None of these actually work.** The `replay.ex` module can read trace files and reconstruct memory state, but it cannot:
- Inject recorded responses back into a live agent execution
- Re-execute operations against real services
- Mix recorded and live I/O

It's a trace reader, not a replay engine.

---

## P2: The Spec Fits in Context -- GRADE: A

> "The complete language specification must fit within 128K tokens. This is a hard constraint."

The spec (`SKEIN_SPEC.md`) is ~23KB / ~6,000-8,000 tokens. The first principles document adds ~43KB / ~11,000-14,000 tokens. Combined, they're ~20,000 tokens -- roughly **15%** of the 128K budget. This leaves massive headroom for task context. The constraint is trivially satisfied and represents genuine discipline in keeping the language small.

---

## P5: Crash Gracefully -- GRADE: A-

> "OTP's 'let it crash' philosophy is the right default."

### What Works

- Agents are `gen_statem` processes with proper supervision (`agent.ex` line 95: `@behaviour :gen_statem`)
- Supervisor declarations compile to metadata that can drive OTP supervision trees
- The `!` operator (unwrap-or-crash) is a first-class construct
- Process isolation is real -- BEAM process boundaries provide actual fault isolation
- `suspend`/`resume` is implemented for human-in-the-loop recovery

### Minor Gaps

- Agent events emitted via `emit` are stored in `gen_statem` data, not the EventStore. If the agent crashes, those events are lost.
- The EventStore itself is ETS-only (volatile). All traces and events vanish on BEAM restart. No persistent storage backend exists.
- Scheduled handlers have no automatic timer-based firing -- only manual `trigger/1`. A scheduled process that crashes and restarts won't actually resume its schedule.

---

## P6: Humans Read, Agents Write, Both Succeed -- GRADE: C+

> "Syntax should be readable by humans and reliably generable by LLMs."

### Structured Errors: Partial

The first principles (Section 10.2) promise every error has `fix_hint` and `fix_code`. Reality:

- **`fix_hint`**: Present on all 24 error/warning codes. Good.
- **`fix_code`**: Present on only 5 of 24 codes (E0012, E0014, E0030, E0032, W0001). The most common error -- E0020 (type mismatch) -- never has `fix_code`.
- **`context`**: Declared on the `Skein.Error` struct but **never populated** by the analyzer. Always `nil`.

An LLM trying to self-correct from a type mismatch error gets a `fix_hint` (English text) but no `fix_code` (exact code to apply) and no `context` (the source line that triggered it). The self-correction loop is weaker than advertised.

### The Spec's Own Examples Don't Compile

This is the most damaging finding for agent-writability. The canonical examples in `SKEIN_SPEC.md` (Sections 8.2-8.5) use syntax features that **do not exist in the implementation**:

| Feature Used in Spec Examples | Implemented? |
|-------------------------------|-------------|
| Object literals: `{ "error": "not found" }` | **No** -- no map literal parsing |
| Record construction: `{ id: Uuid.new(), email: input.email }` | **No** |
| Named arguments: `model: "claude-sonnet-4-5", system: "..."` | **No** -- positional only |
| Tuple destructuring: `let (status, body) = ...` | **No** |
| Unit type: `Result[(), StoreError]` | **No** |
| Anonymous function in stubs: `fn _ -> Ok(...)` | **No** |
| `agent.final_phase`, `agent.events`, `agent.suspended` | **No** |
| `RefundAgent.run_sync(...)` | **No** |
| `stubs: { ... }` for test mocking | **No** |

If an LLM is given `SKEIN_SPEC.md` as context and generates code following the examples, **that code will not compile.** The spec teaches patterns the language cannot parse. This is the exact opposite of what P6 promises.

The actual `.skein` example files in the repo are much simpler than the spec examples -- they avoid all of these features. Compare the spec's `RefundService` (Section 8.4) with the actual `refund_agent.skein`: the real file has no type declarations, no tool definitions, no object literals, no store operations, and no named arguments. It compiles because it avoids the features the spec showcases.

---

## Agent System -- GRADE: B

> "An agent in Skein is an explicitly defined state machine running as a supervised OTP process."

### What Works Well

- `gen_statem` implementation is correct and idiomatic
- Phase transitions are compile-time validated (E0030, E0031, E0032)
- `transition()`, `stop()`, `suspend()` all generate correct return tuples
- Phase metadata is exposed via `__phases__/0`
- The agent lifecycle (start -> phase handlers -> stop/suspend) is real

### What's Missing

**Agent-instance memory scoping is not implemented.** The first principles (Section 6.3) say:

> "Inside an agent, memory is implicitly scoped to the agent instance. `memory.put("decision", decision)` is stored as `RefundAgent:<instance_id>:decision`"

In reality, memory is namespace-scoped, not instance-scoped. Two concurrent `RefundAgent` instances sharing a `memory.kv` namespace will overwrite each other's keys. The agent runtime injects no instance-specific prefix.

**Agents cannot be nested inside modules.** The parser's `parse_declaration` has no `{:agent, _}` clause, yet the spec (Section 8.4) shows `agent RefundAgent { ... }` nested inside `module RefundService { ... }`. The canonical refund example from the spec would fail to parse.

**No production LLM backend.** The `llm.ex` module has a proper backend behaviour with 7 test backends (deterministic, failing, invalid JSON, streaming variants), but **zero HTTP backends**. No real LLM provider can be called without implementing a custom backend. The agents "work" only with canned responses.

**`agent_statem_test.exs` is broken.** The stateful property test for agent lifecycle fails to compile because it depends on `Skein.Compiler` from a sibling umbrella app. The one test that would verify agents work through full `gen_statem` lifecycle execution doesn't run.

---

## Tool System -- GRADE: B-

> "Tools separate contract from implementation."

The architecture is right: ETS registry with `{name, schema, impl}` tuples. Schema generation produces LLM function-calling manifests. `tool.call`/`tool.list`/`tool.schema` all work.

But:
- **No input validation.** Tool inputs go directly to the implementation function without schema validation. The `validation_error` variant exists in `Tool.Error` but is never constructed.
- **Runtime capability check is not name-specific.** `tool.call(AnyTool)` succeeds as long as *any* `tool.use` capability is declared, regardless of which tool names it lists.

---

## What the First Principles Document Gets Right

Despite the gaps, several design choices are well-executed:

1. **Small language surface area.** 12 constructs, fitting on one page. The spec is genuinely compact.
2. **Capability checking at compile time.** This is real, thorough, and the strongest part of the analyzer.
3. **Agent phase transitions as compiler-checked state machines.** The transition graph is validated at compile time with three different error codes. This is exactly what the first principles promise.
4. **Automatic tracing.** Every runtime subsystem wraps operations in `Trace.with_span`. This is not aspirational -- it's actually universal.
5. **Structured errors.** All errors are JSON-serializable with error codes and fix hints.
6. **The compilation pipeline works.** `.skein` -> BEAM bytecode -> callable function is real and tested.
7. **Property testing mandate is followed.** 182 property tests across both StreamData and PropCheck. This is rare for a project at this stage.
8. **The LSP is real.** Completions, hover, diagnostics, symbols, semantic tokens, go-to-definition -- not a skeleton.

---

## Summary: Severity-Ranked Issues

### Critical (Undermines Core Promises)

1. **Type system is `:unknown`-dominated.** Field access, pattern bindings, user types, FnRef, and most complex expressions all infer to `:unknown`. The "Types Are Contracts" principle (P3) is not delivered.
2. **Spec examples don't compile.** Object literals, named arguments, tuple destructuring, and record construction syntax are described in the spec but not implemented. An LLM given the spec will generate broken code.
3. **Runtime capability enforcement has major holes.** Tool, LLM, Topic, Process, Timer, and EventStore either check only for presence or don't check at all.

### Serious (Significant Functionality Gaps)

4. **Agents cannot nest inside modules** despite the spec showing this pattern.
5. **Agent memory is not instance-scoped** despite the spec explicitly promising it.
6. **Replay is a trace reader, not a replay engine.** None of the three advertised modes work.
7. **No production LLM backend.** Agents can only use canned test responses.
8. **Error `context` field is always nil.** Error `fix_code` is missing from 19 of 24 error codes.
9. **Division codegen uses integer `:div` unconditionally.** Float division will crash.
10. **Multiple `emit` calls in a handler sequence lose all but the last event.**

### Moderate (Spec/Implementation Drift)

11. Keyword count is 38, not ~25.
12. `resume` keyword is reserved but has no parser production.
13. Map literal AST node exists but has no parser support.
14. Guard expressions in match arms: AST field exists, always `nil`.
15. Enum exhaustiveness warning uses wrong error code (E0024 instead of E0021).
16. `queue.consume` in spec vs `queue.in` in implementation.
17. Schedule handlers have no automatic timer-based firing.
18. Agent `emit` events are not stored in the EventStore.

### Minor (Documentation/Bookkeeping)

19. CLAUDE.md AST examples have outdated field names.
20. Implementation plan post-MVP backlog lists LSP and `llm.embed` as future work (both done).
21. Docs site homepage test count is stale (651 vs actual ~1,176).
22. Single `|` token in lexer is not in the spec.
23. `idempotent` keyword not in spec's keyword list.

---

## Recommendations

**If I could change three things:**

1. **Make the type system real.** Resolve field access types by tracking user type field maps in the environment. Propagate types through pattern bindings. Even without full Hindley-Milner inference, a structural approach where `user.email` looks up the `email` field type from the `User` type declaration would catch the vast majority of real bugs. This is the single highest-leverage improvement.

2. **Align the spec examples with reality or implement the missing syntax.** Either add object literals + named arguments + tuple destructuring to the parser, or rewrite the spec examples to use only implemented syntax. The current state -- where the spec teaches patterns that don't compile -- is actively harmful to the agent-writability mission.

3. **Close the runtime capability gaps.** Make `check_model_capability` actually compare provider/model strings. Make `check_tool_capability` verify the specific tool name. Add real checks to Topic, Process, Timer, and EventStore. The compile-time checks are meaningless if the runtime lets everything through.
