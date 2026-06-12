---
title: Stability & Versioning
description: What semver means for Skein at 1.0 — the stability class of every public surface, release cadence, spec versioning, and the deprecation policy.
---

**Status:** applies from v1.0.0 onward.

Skein is a language, a runtime, and a toolchain that ship together as one
versioned artifact. "Semver" therefore means more here than it does for a
library: a Skein version number makes promises about source programs, about
machine-consumed compiler output, and about persisted runtime data — not just
about an Elixir API.

A version is `MAJOR.MINOR.PATCH`:

- **PATCH** (`1.0.x`) — bug fixes only. No surface changes of any kind: a
  program that compiled cleanly keeps compiling with identical diagnostics,
  and no new language surface, flags, or config keys appear.
- **MINOR** (`1.x.0`) — additive changes. New language constructs, new stdlib
  functions, new error codes, new CLI flags and `skein.toml` keys, new effect
  methods. Existing programs compile and behave identically.
- **MAJOR** (`2.0.0`) — breaking changes, including removals of deprecated
  surface.

## Stability classes

Every public surface belongs to one of three classes:

- **Stable** — covered by the promises above. Breaking it requires a major
  release.
- **Evolving** — may gain capability in minor releases; consumers must
  tolerate additions (new map keys, new fields, new enum members). Removals
  and shape changes still require a major.
- **Internal** — no compatibility promise at any version. Do not build on it.

| Surface | Class | Notes |
|---|---|---|
| Language: spec grammar + semantics | **Stable** | See "The language" below |
| Error and warning codes (`E####`/`W####`) | **Stable, append-only** | See "Error codes" below |
| Compiled-module metadata (`__handlers__/0`, `__tools__/0`, `__tests__/0`, `__supervisors__/0`) | **Evolving** | Entries may gain fields in minors; existing fields never change meaning |
| EventStore persisted event shapes (SQLite) | **Stable, additive** | Replay depends on them; see "Stored traces" below |
| `skein.toml` format | **Stable** | New keys in minors; unknown keys are never errors |
| CLI commands and flags | **Stable** | New commands/flags in minors; removals/renames major |
| JSON Schema derivation | **Stable** | The schema derived from a given type declaration only changes in a major |
| Tooling protocols: MCP tool result shapes, LSP diagnostic `data` payload | **Evolving** | Additive in minors — consumers must ignore unknown keys |
| Compiler module APIs (`Skein.Lexer`, `Skein.Parser`, `Skein.Analyzer`, `Skein.CodeGen.*`) | **Internal** | The CLI/MCP/LSP are the supported entry points |
| Core Erlang output shape | **Internal** | Only the *behavior* of compiled code is promised |
| Runtime module APIs not reachable from Skein source | **Internal** | e.g. `Skein.Runtime.EtsTables`, backend internals |

### The language

The spec (`docs/SKEIN_SPEC.md`) is the contract. A breaking change is anything
that makes a previously valid program fail to compile or change behavior —
including new *reserved* keywords, which would break programs using that word
as an identifier. Skein's contextual-keyword machinery exists precisely to
keep additions non-breaking: new constructs prefer contextual keywords
(recognized only in their position, usable as identifiers everywhere else —
as `if` is in match-arm guards) over reserved ones.

New *warnings* are additive and may appear in minors; new *errors* on
previously-accepted programs are breaking, with one exception: a program that
only compiled because of a compiler bug (accepted surface the spec already
prohibited) may start erroring in a patch, with a changelog note.

### Error codes

Diagnostic codes are machine-consumed — LSP code actions, MCP
`skein_compile_check`, and agents key off the `code` field. After 1.0:

- Codes are **append-only**: a code is never renumbered, repurposed, or
  deleted (a code can stop being emitted, but its meaning is retired with it).
- The structured shape (`code`, `severity`, `message`, `location`,
  `fix_hint`, `fix_code`, `context`) only gains fields.
- Message *text* may be reworded in minors; tooling must key off `code`, not
  message text.

### Stored traces (EventStore schema)

Recorded traces are replayable data: events recorded by any 1.x runtime
replay on every later 1.y (y ≥ x). Event shapes only gain fields within 1.x;
existing fields are never renamed or repurposed. A major release may change
the storage schema, in which case it must document a JSON export path for
traces worth keeping (no export command ships in 1.0).

### `skein.toml` and the CLI

Config keys and CLI flags are additive within a major. Unknown `skein.toml`
keys are ignored (never errors), so a project file written for 1.x parses on
1.0. Flag *defaults* don't change within a major.

### JSON Schema derivation

External systems consume derived schemas (LLM structured output, tool input
validation). For a fixed type declaration, the derived schema is stable
within a major: same properties, same `required`, same variant encoding. New
type-system constructs map to *new* schema output without altering the output
for existing declarations.

## Release cadence and branching

- Releases are cut from `main` by the auto-tag flow: a green version-bump
  merge tags and publishes (binaries, docs snapshot, GitHub Release).
- There are no long-lived release branches by default. A `release/1.x` branch
  is created on demand only when a severe defect needs a patch after `main`
  has moved on to unreleasable work.
- Patches ship as needed; minors ship when additive work accumulates; there
  is no calendar cadence.

## Spec versioning

The spec is frozen per minor: each `1.x.0` release snapshots the docs
(including the spec and the `llms*.txt` endpoints) under that version, and
the spec does not change for the lifetime of that minor except for erratum
fixes that don't alter surface. The spec version is the binary version that
shipped it.

## Deprecation policy

- Surface is deprecated in a minor (compiler warning or documented notice),
  stays functional for the remainder of the major, and is removed no earlier
  than the next major.
- Diagnostic *hints* that mention old names (like the `queue.in` →
  `queue.consume` rename hint on E0012) are not deprecated surface; they stay
  as long as they help.
- Anything still deprecated when a major ships is removed in that major —
  majors do not carry deprecated surface forward.
