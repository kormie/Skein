# Skein Project Memory

## Project State
- Phases 1-7 + 8a + 8c are complete
- 664 tests + 70 properties, 0 failures
- Elixir 1.19.5, OTP 28, managed by mise

## Key Patterns
- Tests must use `--no-start` or run via `mix test` (umbrella)
- Module names: `Skein.User.{Name}` for modules, `Skein.Agent.{Name}` for agents
- All test constructs (test/scenario/golden) use `__test_N__/0` functions and `__tests__/0` metadata
- Trace.init/0 uses try/rescue around ETS creation for concurrent safety
- Parser uses `expect_ident_value` for contextual keywords (from, trace)
- `compile_string/1` is the test helper for integration tests

## Common Issues
- ETS race condition: Always wrap `:ets.new` in try/rescue when called from multiple processes
- Property tests: Avoid generating keywords as identifiers (prefix with "z")
- Codegen scope threading: Given vars must be in scope when generating expect body
- Parser: `from` and `trace` in golden tests are identifiers, not keywords

## What's Next
- 8b: Storage Backend (Ecto integration)
- 8d: Canonical Examples (hello_http, refund_agent, incident_triage, queue_worker)
- 8e: Queue and Schedule Handlers
- 8f: LLM Streaming
