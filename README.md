# Skein Development Kit

Everything you need to start building the Skein programming language compiler and runtime.

## Contents

```
skein-dev-kit/
├── README.md                          # This file
├── CLAUDE.md                          # Claude Code project instructions (copy to project root)
├── bootstrap.sh                       # Run this to create the Elixir project
├── docs/
│   ├── SKEIN_SPEC.md                  # Complete language specification
│   ├── ARCHITECTURE.md                # Compiler + runtime architecture
│   ├── IMPLEMENTATION_PLAN.md         # 7-phase build plan with acceptance criteria
│   └── skein_first_principles.md      # Language design rationale
```

## Getting Started

### Prerequisites

- Erlang/OTP 27+ (`brew install erlang` or use asdf)
- Elixir 1.17+ (`brew install elixir` or use asdf)
- Git

### Bootstrap

```bash
chmod +x bootstrap.sh
./bootstrap.sh
cd skein
mix deps.get
mix test
```

This creates a fully scaffolded Elixir umbrella project with stub implementations,
test files, and example `.skein` programs.

### Start a Claude Code Session

```bash
cd skein
# CLAUDE.md is already in the project root
# Claude Code will read it automatically

claude
```

Tell Claude Code: **"Read CLAUDE.md and the docs. Start Phase 1 — implement the lexer."**

## Development Phases

| Phase | Goal | Est. Weeks |
|-------|------|-----------|
| 1 | Hello BEAM — end-to-end compilation pipeline | 2 |
| 2 | Type system — named types, enums, type checking, schema derivation | 2 |
| 3 | Capabilities — declared effects, compile-time + runtime checking | 2 |
| 4 | HTTP handlers — routing, request/response, running server | 1-2 |
| 5 | Storage — store.table, typed records, migrations | 1 |
| 6 | Agents — state machines, LLM calls, tools, memory | 3 |
| 7 | Testing & CLI — test constructs, replay, golden traces, CLI | 2 |

See `docs/IMPLEMENTATION_PLAN.md` for full details.

## Document Guide

| Document | Audience | Purpose |
|----------|----------|---------|
| `CLAUDE.md` | Claude Code | Project conventions, architecture decisions, what to do and what not to do |
| `SKEIN_SPEC.md` | Compiler implementer | The truth — every syntax rule, type rule, and standard library function |
| `ARCHITECTURE.md` | Compiler implementer | How the pieces fit together — pipeline, runtime, supervision tree |
| `IMPLEMENTATION_PLAN.md` | Project manager | What to build, in what order, and how to know when it's done |
| `skein_first_principles.md` | Language designer | Design rationale, principles, tradeoffs, and the "why" behind every decision |
