# Static and executable audit of 1.0 claims (2026-07-11)

Scope: `README.md`, `docs/ROADMAP.md`, `docs/SKEIN_SPEC.md`, `docs/STABILITY.md`, and docs-site roadmap/reference pages were compared against source modules, frozen vectors, and conformance/runtime tests before promoting the next RC.

## Method

Static checks:

- Searched release-status language and stale completion claims with `rg` across the scoped documents and docs-site pages.
- Mapped each stable-surface claim to the source module that owns the behavior.
- Mapped each claim to an executable test, frozen vector, or conformance corpus entry.

Executable checks:

- Ran the umbrella test suite with `mix test` after the doc corrections.
- Ran targeted conformance/freeze subsets for the frozen 1.0 surfaces.

## Corrections made during this audit

| Document | Finding | Resolution |
|---|---|---|
| `docs/ROADMAP.md` | The re-baseline still said “the next release is not another RC,” which was true before v0.4.0/v0.5.0 shipped but contradicts the active `v1.0.0-rc.5` gate. | Reworded to say GA is not imminent and the active gate is the next true RC (`v1.0.0-rc.5`). |
| `README.md` | “Current version is 0.5.0” contradicted `mix.exs` (`1.0.0-rc.5`) and the README's own CLI example. | Reworded to “current package version is 1.0.0-rc.5” while preserving that 0.5.0 was the last pre-RC development release. |
| `README.md` | “soundness and runtime-contract hardening ... is in progress” lagged the Wave F freeze language and implied unfrozen 1.0 surfaces. | Reworded to say stable surfaces are frozen behind executable gates and GA waits on soak/release mechanics. |
| `docs/site/src/content/docs/reference/agent-quick-reference.md` | “All phases complete — MVP reached” was an over-broad completion claim not tied to the RC/GA gate. | Downgraded to “Pre-1.0 RC gate active,” with conformance-gated frozen surfaces and GA pending soak. |
| `docs/site/src/content/docs/reference/agent-quick-reference.md` | Store summary said the Ecto/SQLite path remains unwired, which is stale for EventStore persistence. | Clarified compiled programs use ETS typed store tables and EventStore persistence uses SQLite. |

## Claim-to-source-to-test matrix

| 1.0 claim retained | Source of truth | Executable enforcement |
|---|---|---|
| Grammar, reserved keywords, and contextual keywords are frozen. | `apps/skein_compiler/lib/skein/lexer.ex`, `apps/skein_compiler/lib/skein/parser.ex`, `conformance/freeze/keywords.json` | `apps/skein_compiler/test/skein/freeze/keywords_freeze_test.exs`, `apps/skein_compiler/test/skein/parser_termination_test.exs`, `apps/skein_compiler/test/skein/lexer_test.exs`, `apps/skein_compiler/test/skein/parser_test.exs` |
| Diagnostic registry and structured diagnostic fields are frozen. | `apps/skein_compiler/lib/skein/error.ex`, `conformance/freeze/diagnostics.json` | `apps/skein_compiler/test/skein/freeze/diagnostics_freeze_test.exs`, `apps/skein_compiler/test/skein/conformance/negative_corpus_test.exs`, `apps/skein_compiler/test/skein/compiler_errors_test.exs` |
| Effect ABI is authoritative and drift-tested. | `apps/skein_compiler/lib/skein/effect_abi.ex`, `conformance/freeze/effect_abi.json` | `apps/skein_compiler/test/skein/effect_abi_test.exs`, `apps/skein_compiler/test/skein/freeze/effect_abi_freeze_test.exs`, `apps/skein_runtime/test/skein/runtime/effect_abi_matrix_test.exs` |
| `llm.json[T]`, `req.json[T]`, and tool input/output validation share the recursive schema engine. | `apps/skein_runtime/lib/skein/runtime/json_schema.ex`, `apps/skein_compiler/lib/skein/codegen/schema_gen.ex` | `apps/skein_compiler/test/skein/integration/schema_engine_test.exs`, `apps/skein_runtime/test/skein/runtime/json_schema_test.exs`, `apps/skein_compiler/test/skein/integration/req_json_test.exs`, `apps/skein_compiler/test/skein/integration/tool_test.exs` |
| Store tables are typed and runtime writes are schema-checked. | `apps/skein_runtime/lib/skein/runtime/store.ex`, `apps/skein_compiler/lib/skein/analyzer.ex` | `apps/skein_compiler/test/skein/integration/typed_store_test.exs`, `apps/skein_compiler/test/skein/integration/store_primary_test.exs`, `apps/skein_runtime/test/skein/runtime/store_test.exs`, `apps/skein_runtime/test/skein/runtime/store_property_test.exs` |
| EventStore persistence is wired and persisted shapes are frozen. | `apps/skein_runtime/lib/skein/runtime/event_store.ex`, `apps/skein_runtime/lib/skein/runtime/event_store/sqlite_backend.ex` | `apps/skein_runtime/test/skein/runtime/event_store_persistence_test.exs`, `apps/skein_runtime/test/skein/runtime/event_store_freeze_test.exs`, `apps/skein_runtime/test/skein/runtime/event_store/sqlite_backend_test.exs`, `apps/skein_runtime/test/skein/runtime/agent_event_store_test.exs` |
| Scenario-scoped capability environments are the 1.0 testing surface; `via` is out. | `apps/skein_compiler/lib/skein/parser.ex`, `apps/skein_compiler/lib/skein/analyzer.ex`, `apps/skein_runtime/lib/skein/runtime/test_policy.ex` | `apps/skein_compiler/test/skein/integration/scenario_envelope_test.exs`, `apps/skein_compiler/test/skein/integration/scenario_envelope_exec_test.exs`, `apps/skein_compiler/test/skein/conformance/positive/scenario_providers.skein`, `apps/skein_compiler/test/skein/conformance/negative/scenario_envelope_incomplete.skein` |
| Tool `policy` blocks are cut from 1.0. | `apps/skein_compiler/lib/skein/parser.ex` | `apps/skein_compiler/test/skein/conformance/negative/tool_policy_block.skein`, `apps/skein_compiler/test/skein/conformance/negative_corpus_test.exs` |
| `supervisor` declarations boot real OTP supervisors. | `apps/skein_runtime/lib/skein/runtime/supervisor_host.ex` and CLI run dispatch in `apps/skein_cli/lib/skein/cli/main.ex` | `apps/skein_runtime/test/skein/runtime/supervisor_host_test.exs`, `apps/skein_cli/test/cli/run_test.exs` |
| CLI surface, JSON output, config keys, and completions are frozen. | `apps/skein_cli/lib/skein/cli/main.ex`, `apps/skein_cli/lib/skein/cli/json.ex`, `apps/skein_cli/lib/skein/cli/config.ex`, `conformance/freeze/cli_surface.json`, `conformance/freeze/cli_usage.txt`, `conformance/freeze/cli_completions.zsh` | `apps/skein_cli/test/cli/cli_surface_freeze_test.exs`, `apps/skein_cli/test/cli/completions_test.exs`, `apps/skein_cli/test/cli/json_test.exs`, `apps/skein_cli/test/cli/config_test.exs` |
| Docs/spec complete-module fences compile and negative examples keep their annotated diagnostics. | `docs/SKEIN_SPEC.md`, `docs/site/src/content/docs/**/*.md` | `apps/skein_compiler/test/skein/conformance/docs_fences_test.exs` |
| Dogfood conformance is a continuous gate. | `conformance/dogfood.json`, `conformance/dogfood/**`, CLI dogfood runner | `apps/skein_cli/test/cli/dogfood_corpus_test.exs`, `apps/skein_cli/test/cli/dogfood_pins_freeze_test.exs` |
| Agent-writability is measured, recorded, and replayed rather than asserted qualitatively. | `conformance/writability/history.jsonl`, `conformance/writability/recordings.json`, `apps/skein_cli/lib/skein/cli/bench.ex` | `apps/skein_cli/test/skein/cli/bench_test.exs`, `apps/skein_cli/test/skein/cli/bench_replay_test.exs`, `apps/skein_cli/test/skein/cli/bench_history_test.exs` |

## Result

No retained scoped 1.0 claim remains without an identified source owner and executable enforcement. Claims that were stale or broader than the test-backed surface were downgraded in the same change set.
