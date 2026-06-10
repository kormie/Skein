# Changelog

## v0.1.4 (unreleased)

Fixes from v0.1.3 field testing.

### CLI

- **`skein new my-app` generates a valid module name** — hyphens (or anything else that isn't a letter/digit/underscore) in the project directory name produced `module Skein-tests {`, which doesn't compile. Names are now sanitized (`skein-tests` -> `SkeinTests`) and prefixed with `Skein` when they don't start with a letter.
- **Ctrl+C exits cleanly** — long-running commands (`skein lsp`, `skein run`) no longer drop into the BEAM `BREAK:` menu on Ctrl+C (`+Bd` in vm.args).

### CI

- **Prebuilt VS Code extension** — CI packages `skein-vscode.vsix` and attaches it to releases, so installing the extension is a download + `code --install-extension` instead of a local npm build.

### VS Code Extension (0.1.2)

- **The packaged extension actually loads** — `.vscodeignore` excluded `node_modules`, so the `.vsix` shipped without `vscode-languageclient`; the extension module failed to load, which broke activation, the palette commands ("command 'skein.restartServer' not found"), and the language client. Production dependencies are now packaged.
- **Supervised language server** — the GenLSP process tree (buffer, assigns, task supervisor, server) now runs under a `:one_for_all` supervisor, so a crash in a handler restarts the server instead of killing the whole VM.

## v0.1.3 (2026-06-10)

First-run UX release: fixes for the CLI paper cuts hit in real first-use sessions, plus `skein lsp` so editor support works with just the standalone binary.

### CLI

- **`skein lsp`** — the standalone binary now embeds the language server (stdio transport). The VS Code extension no longer needs an Elixir checkout.
- **Errors name the file** — compiler errors print `src/main.skein:3:` instead of `unknown:3:`, and CLI output includes each error's `fix_hint`.
- **Readable file errors** — `File not found: …` and `… is a directory — pass a .skein file, or use 'skein build …'` instead of raw `:enoent` / `:eisdir`.
- **`skein build` / `skein test` / `skein run` default to the current directory** — matching the README that `skein new` generates.
- **Unknown flags are rejected** — `skein build -v .` now errors with `Unknown option: -v` instead of treating `-v` as the project directory.
- **`skein build` prints the actual compile errors** for failing files (with hints), not just the file name.
- **`skein test` reports files that fail to compile** — previously a broken file was silently skipped and the run reported `0 passed, 0 failed`. Compile failures are now printed and fail the run.
- **Stray-source hint** — when `src/` has no sources but `.skein` files sit in the project root, the error says so and points at `skein compile <file>`.

### Compiler

- **Targeted hints for habits from other languages** — `;` explains that Skein has no semicolons; `return` explains that a function returns the value of its last expression.

### CI

- **Lighter PR binary builds** — pull requests build only the native Linux target (release-assembly smoke test) and skip artifact uploads; docs-only PRs skip the job entirely. The full four-target matrix still runs on `main` pushes and `v*` tags.

### VS Code Extension (0.1.1)

- **Command palette entries actually appear** — `Skein: Restart Language Server` and `Skein: Show Language Server Output` were registered but never declared in the manifest. They also work (with a warning) when the server is disabled.
- **Standalone-binary language server** — the extension launches `skein lsp` by default and only uses `mix skein.lsp` inside a Skein compiler checkout. New settings: `skein.lsp.serverCommand` (`auto`/`skein`/`mix`) and `skein.lsp.skeinPath`.

## v0.1.2 (2026-06-10)

Hardening release: full codebase audit resolution plus demo-readiness fixes across the compiler, runtime, examples, and docs.

### Compiler

- **String-literal match patterns** — `match s { "approve" -> ... }` previously crashed the BEAM compiler (`core_to_ssa` on OTP 28). String patterns now compile to proper Core Erlang binary patterns, and matches without a catch-all arm get an explicit `case_clause` failure clause.
- **`method!(args)` / `method?(args)` parsing** — the bang/question mark now binds to the call result, so `store.users.get!(id)` parses as unwrap-of-call. Previously every `.get!(...)` form in the docs produced a mangled parse.
- **Agent `state.field` access** — works in nested expression positions (let values, call arguments, match subjects), not just at the top level of a phase handler.
- **`store.<table>.get!` / `put!`** — let-it-crash store accessors, in the analyzer, codegen, and runtime (`Store.get!/3`, `Store.put!/3`).
- **Capability rename** — queue handlers require `queue.consume` and schedule handlers `schedule.trigger` (aligned with the spec). Declaring the old `queue.in` / `schedule.in` produces a targeted rename hint on E0012.
- **`fix_code` everywhere** — all parser, lexer, and analyzer errors now carry machine-applicable `fix_code` (audit follow-up).

### Runtime

- **Audit resolutions (2026-06-09)** — atom-exhaustion and ETS race fixes, supervised GenServer startup, HTTP method whitelisting, size-bounded EventStore, query filter validation, CLI structured errors. See `docs/AUDIT_2026-06-09.md`.
- **`process.spawn("name")` no longer crashes** — compiled task-name spawns run as supervised, traced no-op tasks (task bodies are a planned extension).
- **Anthropic backend honesty** — removed the silent `gpt-*` → Claude model rewrite; the requested model is passed through unchanged. Replaced the deprecated default model with current model IDs.
- **Timer hardening** — `Timer.reset_all/0` no longer stops the supervised GenServer.

### Examples & Docs

- `examples/README.md` — a guided index of all fourteen examples with run instructions.
- All examples use current Anthropic model IDs (`claude-opus-4-8`); `semantic_search` documents that `llm.embed` needs an embeddings-capable backend.
- README flagship agent example rewritten to code that compiles as-is (and is kept compiling by tests for the constructs it uses).
- Install instructions point at GitHub Releases (binaries are published automatically on `v*` tags).
- `docs/ROADMAP.md` rewritten against a source-verified status pass; the docs site roadmap matches.
- Docs-site freshness pass: current model IDs, capability names, test counts, and the four-app umbrella layout.

### Test Suite

- **1,413 tests + 189 property-based tests**, 0 failures (up from 1,343 + 182). CI enforces format, `--warnings-as-errors`, and the full suite.

## v0.1.1 (2026-02-16)

### Features
- **Real type inference** — field access on typed records now resolves types; `user.email + 42` correctly produces type errors. Pattern bindings extract inner types from Result/enum variants.
- **Schema derivation** — nested user types generate fully resolved JSON Schema. Enum variants produce `oneOf` schemas. `Map[K,V]` generates `additionalProperties`.
- **Capability enforcement** — all 6 effect subsystems (HTTP, store, memory, LLM, tool, topic) now check capabilities at runtime.
- **Production LLM backend** — Anthropic integration with `llm.chat`, `llm.json`, `llm.stream`. Token-level usage tracking. Anti-corruption layer for provider-agnostic response format.
- **Enriched traces** — every effect call produces structured trace spans with timing, outcome, and token usage.
- **Persistent EventStore** — SQLite backend for events (opt-in, ETS remains default).
- **Replay engine** — recorded response injection for deterministic golden tests.
- **Agent memory isolation** — instance-scoped memory prevents concurrent agents from overwriting each other.
- **Tool input validation** — tool calls validated against declared schemas.
- **Error context enrichment** — structured error contexts with source locations.
- **Source text wiring** — `compile_file`/`compile_string` thread source text through for better error reporting.
- **Linux ARM64 builds** — `aarch64` added to distribution targets.

### Fixes
- Float division codegen generates correct Core Erlang
- Contextual keywords (`input`, `from`, `trace`) no longer reserved — usable as variable names
- Multiple `emit` in a single handler now collects all events (previously only the last was kept)
- Capability params codegen handles `ToolRef` and `Identifier` nodes
- Compiler test suite cross-app dependency resolved (181 failures fixed)

### Docs & Spec
- Spec sections 8.2–8.5 rewritten to use implemented syntax
- Landing page, quickstart, and overview rewritten for binary distribution
- Prebuilt binary install instructions added to README
- Comprehensive coverage for Tier 2 features in docs and tests

### Examples
- `market_research_agent.skein` — 5-phase competitive analysis agent with gather↔analyze loop
- `skein_assistant.skein` — stateful conversational agent for Skein code help

### Test Suite
- **1,316 tests + 182 property-based tests**, 0 failures (up from 1,176 + 182 in v0.1.0)

## v0.1.0

Initial release. Full compilation pipeline, 12 language constructs, stdlib, CLI, LSP, docs site.
