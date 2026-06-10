# Skein Examples

Every example in this directory compiles and runs against the current compiler —
all of them are covered by the integration suite
(`apps/skein_compiler/test/skein/examples_test.exs`), so they can't silently rot.
Coverage goes beyond compiling: handlers are invoked, agent phase handlers are
driven, and the `market_research` agent→service `tool.call` path is executed
end-to-end. Paths that need live backends (LLM chat phases, real outbound HTTP,
embeddings) are exercised up to that boundary and documented in each example's
notes.

## Running the examples

**With the `skein` binary** (see [Getting Started](../README.md#getting-started)):

```bash
skein compile examples/hello.skein     # compile one file to BEAM
skein run <project-dir>                # start a service (HTTP/queue/schedule handlers)
```

**From a source checkout:**

```bash
# Verify every example compiles and behaves correctly
mise exec -- mix test apps/skein_compiler/test/skein/examples_test.exs

# Make real LLM calls through compiled Skein code (requires an API key)
ANTHROPIC_API_KEY=sk-ant-... mise exec -- mix run examples/demo.exs
```

## Start here

| Example | What it shows |
|---|---|
| [`hello.skein`](hello.skein) | The smallest Skein program: a module with pure functions, string interpolation, and `match`. |
| [`hello_http.skein`](hello_http.skein) | An HTTP service with multiple endpoints and all three response helpers (`respond.json`, `respond.text`, `respond.html`). |
| [`hello_llm.skein`](hello_llm.skein) | An agent that makes a capability-gated LLM call (`llm.chat`) and transitions through phases. |

## Services and effects

| Example | What it shows |
|---|---|
| [`queue_worker.skein`](queue_worker.skein) | Queue and schedule handlers (`queue.consume`, `schedule.trigger`), plus `idempotent(key)` for exactly-once processing. |
| [`pubsub_notifications.skein`](pubsub_notifications.skein) | Topic pub/sub with fan-out: one publisher, two independent consumers. |
| [`background_tasks.skein`](background_tasks.skein) | `process.spawn` for supervised background tasks and `timer.after` / `timer.interval` / `timer.cancel`. |
| [`audit_log.skein`](audit_log.skein) | Structured event logging with the `event.log` capability. |
| [`supervisor_pool.skein`](supervisor_pool.skein) | `supervisor` declarations: restart strategies and a worker pool next to an HTTP server. |
| [`stdlib_demo.skein`](stdlib_demo.skein) | A tour of the standard library (String, List, Map, Option, Result, ...). |

## Agents

| Example | What it shows |
|---|---|
| [`refund_agent.skein`](refund_agent.skein) | The canonical agent: a compile-time-checked phase machine, instance-scoped memory, an LLM decision step, and `suspend()` for human review. |
| [`incident_triage.skein`](incident_triage.skein) | A multi-phase triage workflow: classify, investigate, escalate-or-resolve, with `emit` events at each outcome. |
| [`skein_assistant.skein`](skein_assistant.skein) | A stateful conversational agent behind an HTTP endpoint, with per-session memory. |
| [`semantic_search.skein`](semantic_search.skein) | RAG-style search with `llm.embed` + `llm.chat`. Note: embeddings need a backend that implements `embed/2` (Anthropic has no embeddings API — see the file header). |

## Multi-file project

[`market_research/`](market_research/) is the architectural reference: a module
that declares tools and HTTP endpoints, plus an agent that is pure workflow
logic calling those tools. It ships in two equivalent shapes — two files
(`service.skein` + `agent.skein`) and one file (`single_file.skein`, with the
agent nested inside the module). It has
[its own README](market_research/README.md) with the full design walkthrough.
If you read only one example deeply, read this one.

## Live LLM demo

[`demo.exs`](demo.exs) is an Elixir script (not a `.skein` file) that compiles a
Skein module on the fly, wires up the production Anthropic backend, and makes
real `llm.chat` calls — showing capability gating, typed results, and automatic
trace spans with token usage. It's the fastest way to see the whole pipeline do
something real:

```bash
ANTHROPIC_API_KEY=sk-ant-... mise exec -- mix run examples/demo.exs
```
