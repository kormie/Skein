---
title: Agent Primer
description: Compact Skein language primer scaffolded into every project as AGENTS.md — syntax cheatsheet, capability rules, agent basics, gotchas, and CLI commands for coding agents.
sidebar:
  order: 2
---

This page is the source of the generated section of `AGENTS.md` that `skein new`
and `skein agents` write into Skein projects. It is a compact primer for coding
agents working inside a Skein project, not a guide to the Skein compiler
codebase itself.

## What Skein Is

Skein is a programming language for cloud services where AI agents are
first-class constructs. It compiles to BEAM bytecode and runs on the Erlang VM.
Source files use the `.skein` extension. Comments start with `--`.

## Project Layout and Commands

```
skein.toml      -- project config
src/*.skein     -- source modules (one module or agent per file)
test/*.skein    -- test modules
```

| Command | Purpose |
|---------|---------|
| `skein build` | Compile all `.skein` files under `src/` |
| `skein test` | Run all `test`/`scenario` declarations in `src/` and `test/` |
| `skein run` | Start the service (HTTP handlers; `--port <n>`, default 4000) |
| `skein compile <file>` | Compile a single file |
| `skein trace` | View recent trace spans (`--last <n>`, `--kind <kind>`) |
| `skein agents` | Regenerate the generated block of this file |
| `skein mcp` | Start the Skein MCP server (stdio) for spec lookup, docs search, and compile checks |

Compiler errors are structured: every error has a `code`, `message`,
`location`, and usually a `fix_hint` and `fix_code` telling you exactly what to
change. Read them — they are written for agents.

## Syntax Cheatsheet

```
-- A module: capabilities, types, functions, handlers, tools, tests
module UserService {
  capability http.in
  capability store.table("users")

  type User {
    id: Uuid @primary
    email: Email @unique
    name: String
  }

  fn greet(name: String) -> String {
    "Hello, ${name}!"          -- string interpolation is ${expr}
  }

  handler http GET "/users/:id" (req) -> {
    let id = Uuid.parse!(req.params.id)
    match store.users.get(id) {
      Ok(u)         -> respond.json(200, u)
      Err(NotFound) -> respond.json(404, { error: "not found" })
    }
  }

  test "greet works" {
    assert greet("World") == "Hello, World!"
  }
}
```

Core forms:

- `let x = expr` — single-assignment binding; type is inferred.
- `match expr { Pattern -> expr ... }` — arms must cover all enum variants and
  all return the same type.
- `expr |> fn_name(args)` — pipe.
- `expr!` — unwrap a `Result`, crashing on `Err`. `expr?` — propagate the
  `Err` to the caller (enclosing function must return `Result`).
- Function params and return types are always annotated:
  `fn add(a: Int, b: Int) -> Int { a + b }`.
- Calls may pass arguments by name after any positional ones:
  `add(b: 2, a: 1)`, `llm.chat(model: "...", system: "...", input: t)`.
  Named args work for same-module fns and documented effect signatures;
  stdlib calls are positional only. Never put a positional arg after a
  named one.
- Built-in types: `Int`, `Float`, `String`, `Bool`, `Uuid`, `Instant`,
  `Duration`, `Email`, `Url`, `Option[T]`, `Result[T, E]`, `List[T]`,
  `Map[K, V]`, `Set[T]`. Field constraints: `@min(n)`, `@max(n)`,
  `@one_of([...])`, `@default(v)`, `@description(s)`, `@primary`, `@unique`.
- Stdlib modules (`String`, `Int`, `Float`, `List`, `Map`, `Set`, `Option`,
  `Result`, `Uuid`, `Instant`, `Duration`) are ambient — no capability or
  declaration needed: `String.upcase(s)`, `List.map(items, &double)`.

## Capabilities and Effects

Every effect call requires a matching `capability` declaration in the same
module or agent. There are no exceptions.

| Capability | Grants |
|------------|--------|
| `http.in` | Declaring `handler http ...` |
| `http.out("host")` | `http.get/post/put/delete` to that host |
| `store.table("name")` | `store.<name>.get/put/delete/query` |
| `memory.kv("namespace")` | `memory.put/get/get!/delete/list` |
| `model("provider", "model")` | `llm.chat/json/stream/embed` |
| `tool.use(Mod.ToolName)` | `tool.call(Mod.ToolName, { ... })` |
| `queue.publish("name")` / `queue.consume("name")` | `queue.publish` / `handler queue` |
| `topic.publish("name")` / `topic.consume("name")` | `topic.publish` / `handler topic` |
| `schedule.trigger("name")` | `handler schedule` |
| `event.log("stream")` | `event.log(name, data)` |
| `process.spawn` / `timer` | `process.spawn` / `timer.after/interval/cancel` |

`emit EventName { field: value }` and `trace.annotate(key, value)` need no
capability. `idempotent(key)` (handlers only) skips re-processing a key.

## Modules Are Sealed: Tools Are the Only Cross-Module Seam

Functions, types, and handlers are private to their module. There is no
`import` and no `OtherModule.fn_name(...)` — that is a compile error (E0016).
To share behavior across modules, declare a `tool` in one module and call it
from another:

```
-- callee module
tool Billing.CreateRefund {
  description: "Issue a refund"
  input  { customer_id: String, amount: Int @min(1) }
  output { id: String, status: String }
  implement { ... }
}

-- caller module (or agent)
capability tool.use(Billing.CreateRefund)
let result = tool.call(Billing.CreateRefund, { customer_id: cid, amount: 500 })
```

## Agents, Phases, and Transitions

Agents are top-level declarations (not nested in modules) with state, a
`Phase` enum declaring legal transitions, and `on` handlers. Transitions are
checked at compile time — `transition()` to a phase not listed in the current
phase's `-> [...]` list is an error (E0030), and every phase needs an
`on phase` handler (E0032).

```
agent RefundAgent {
  capability memory.kv("refund_sessions")

  state { ticket_id: String }

  enum Phase {
    Analyze -> [Refund, Done]
    Refund  -> [Done]
    Done    -> []
  }

  on start(ticket_id: String) -> {     -- typed params, NOT `on start(ctx)`
    memory.put("ticket_id", ticket_id)
    transition(Phase.Analyze)
  }

  on phase(Phase.Analyze) -> {
    -- decide, then:
    transition(Phase.Refund)
  }

  on phase(Phase.Refund) -> { transition(Phase.Done) }
  on phase(Phase.Done) -> { stop() }   -- stop() needs the parens
}
```

Agent lifecycle calls (inside agents only): `transition(Phase.X)`, `stop()`,
`suspend(reason)`, `resume(input)`. Memory keys are automatically scoped per
agent instance.

## Known Gotchas

- `input` is a keyword — never use it as a parameter or binding name (use
  `ctx`, `data`, or a typed name).
- `stop()` must be called with parentheses.
- `on start` takes typed parameters (`on start(order_id: String)`), not a
  bare context argument.
- Match arms must all return the same type, and enum matches must cover every
  variant (or use `_`).
- One module (or one agent) per file; modules cannot contain agents.
- `handler queue`/`handler topic` take the queue/topic name as a string route;
  `handler schedule` handlers take no payload parameter.
- String interpolation is `${expr}`; comments are `--` (not `//` or `#`).

## Going Deeper

- Full language spec, examples, and stdlib reference (agent-friendly):
  - https://kormie.github.io/Skein/llms.txt (entry point)
  - https://kormie.github.io/Skein/llms-small.txt (compact)
  - https://kormie.github.io/Skein/llms-full.txt (full corpus)
- On-demand spec lookup, docs search, and structured compile checks without
  leaving your editor: register the Skein MCP server. It speaks MCP over
  stdio:

  ```bash
  # Claude Code
  claude mcp add skein -- skein mcp
  ```

  Tools: `skein_spec_lookup` (fetch a spec section), `skein_docs_search`
  (search the spec corpus), `skein_compile_check` (compile a file or project
  and get structured JSON errors with fix hints).
