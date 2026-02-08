# Skein Project Memory

## Project State
- Phases 1-7 + 8a + 8c + 8d + 8e are complete
- Remaining: 8b (Ecto storage), 8f (LLM streaming)
- 727 tests + 72 properties, 0 failures
- Elixir 1.19.5, OTP 28, managed by mise

## Key Patterns
- Tests must use `--no-start` or run via `mix test` (umbrella)
- Module names: `Skein.User.{Name}` for modules, `Skein.Agent.{Name}` for agents
- All test constructs (test/scenario/golden) use `__test_N__/0` functions and `__tests__/0` metadata
- Trace.init/0 uses try/rescue around ETS creation for concurrent safety
- Parser uses `expect_ident_value` for contextual keywords (from, trace)
- `compile_string/1` is the test helper for integration tests
- `compile_file/1` is the integration test helper for .skein file examples

## Key Technical Details
- `input` is a keyword token in Skein — use `ctx` or typed params in agents
- `stop` must be called as `stop()` with parens in agent handlers
- Handler AST: `%Handler{source, method, route, param, body, meta}` — `method` is nil for queue/schedule
- Test files run from app dirs — use `Path.join(__DIR__, "..", "..", "..", "..")` for project-root-relative paths
- GenServer `reset_all/0` in tests needs try/catch for exit races in `on_exit` callbacks
- `mix format` auto-runs and may reformat test files
- Agent `on start` requires typed parameters: `on start(order_id: String)`, not `on start(ctx)`

## Architecture Notes
- Parser: `parse_handler` branches on source type (http/queue/schedule)
- Analyzer: `handler_required_capability/1` maps source -> capability name (http.in/queue.in/schedule.in)
- CodeGen: `__handlers__/0` includes `source` field (:http, :queue, :schedule)
- Runtime Queue/Schedule: GenServer-based, self-starting via `ensure_started/0`
- Compilation: `compile_file/1` and `compile_string/1` in `Skein.Compiler`
- Analyzer helper functions must come after all clauses of a `validate_declaration` defp to avoid ungrouped clauses warning

## Common Issues
- ETS race condition: Always wrap `:ets.new` in try/rescue when called from multiple processes
- Property tests: Avoid generating keywords as identifiers (prefix with "z")
- Codegen scope threading: Given vars must be in scope when generating expect body
- Parser: `from` and `trace` in golden tests are identifiers, not keywords
- GenServer cleanup race: `on_exit` callbacks may run after GenServer dies — wrap in try/catch :exit
- Schedule/Queue nil handling: method is nil for non-HTTP handlers, param is nil for schedule handlers

## File Locations
- Parser: `apps/skein_compiler/lib/skein/parser.ex`
- Analyzer: `apps/skein_compiler/lib/skein/analyzer.ex`
- CodeGen: `apps/skein_compiler/lib/skein/codegen/core_erlang.ex`
- Runtime Queue: `apps/skein_runtime/lib/skein/runtime/queue.ex`
- Runtime Schedule: `apps/skein_runtime/lib/skein/runtime/schedule.ex`
- Examples: `examples/` (hello.skein, hello_http.skein, refund_agent.skein, incident_triage.skein, queue_worker.skein)
- Examples Tests: `apps/skein_compiler/test/skein/examples_test.exs`
- Docs site: `docs/site/src/content/docs/`
- Sidebar: `docs/site/astro.config.mjs`

## User Preferences
- Use mermaid diagrams for human-focused docs, DOT for LLM docs
- TDD is mandatory — write tests before implementation
- Property tests (StreamData) required where inputs have wide spaces
- The compiler should validate all Phase enum clauses have `on phase` handlers (already done: E0032)

## What's Next
- 8b: Storage Backend (Ecto integration)
- 8f: LLM Streaming
