# Market Research Agent + API

A multi-phase agent with a companion HTTP module, demonstrating the agent-plus-module pattern in Skein.

## Architecture

```
┌──────────────────┐     ┌──────────────────────┐
│  api.skein       │     │  agent.skein          │
│  (HTTP module)   │────▶│  (stateful agent)     │
│                  │     │                       │
│  POST /start     │     │  Briefing             │
│  GET  /status    │     │  ↓                    │
│  POST /resume    │     │  Gathering ──suspend──│──▶ human refines scope
│  GET  /report    │     │  ↓                    │
│                  │     │  Analyzing            │
│                  │     │  ↓                    │
│                  │     │  Reporting            │
│                  │     │  ↓                    │
│                  │     │  Complete             │
└──────────────────┘     └──────────────────────┘
```

## Phase Flow

1. **Briefing** — Records the research topic, annotates trace
2. **Gathering** — Asks LLM if scope is focused enough. If "no", suspends for human refinement. Otherwise identifies competitors via LLM.
3. **Analyzing** — Competitive landscape analysis + SWOT generation via LLM
4. **Reporting** — Generates final report with recommendations
5. **Complete** — Stops the agent

## HTTP API (api.skein)

| Endpoint | Method | Description |
|---|---|---|
| `/research/start` | POST | Start research. Body: `{"topic": "...", "industry": "...", "focus_areas": "..."}` |
| `/research/status` | GET | Check current phase and status |
| `/research/resume` | POST | Resume suspended agent. Body: `{"refined_topic": "..."}` |
| `/research/report` | GET | Retrieve final report |

The API module uses `req.json[T]!` for typed request body parsing with automatic JSON Schema validation.

## Suspend/Resume Pattern

In the Gathering phase, the agent checks scope breadth via LLM. If too broad:
```
let is_too_broad = String.contains(scope_check, "no")
match is_too_broad {
  true -> suspend("Requires human scope refinement")
  false -> { ... proceed ... }
}
```

The agent suspends and waits for a human to provide a refined topic via `POST /research/resume`.

## Language Gaps Discovered

These were found while building this example and are documented for future language development:

1. **No `if` expression** — Must use `match bool { true -> ... false -> ... }` pattern. Works but verbose.

2. **`resume` is a keyword** — Cannot use `resume` as a variable name. Workaround: use `body` or another name.

3. **No agent-to-module communication** — There's no way for a module to spawn, call, or query an agent instance. The API module currently returns placeholder data. Needs: `agent.spawn()`, `agent.send()`, `agent.query()` primitives.

4. **No map literal returns from handlers** — Can't construct ad-hoc response objects. Must respond with strings or typed objects from `req.json[T]`.

5. **Type declarations are parse-only for `req.json[T]`** — You can declare `type Foo { ... }` and use it with `req.json[Foo]!`, but there's no way to construct a `Foo` instance in code (no type constructors). Types exist only for JSON schema validation.

6. **No memory access from modules** — Only agents have `memory.kv`. A companion module can't read the agent's memory to return status. Needs a cross-module query mechanism or shared state.

7. **Trace annotations in agents use implicit scope** — `trace.annotate` works in both modules and agents but trace spans aren't queryable from outside.

## Files

- `agent.skein` — The market research agent (5 phases, suspend/resume, LLM integration)
- `api.skein` — Companion HTTP module (4 endpoints, typed request parsing)
- `README.md` — This file
