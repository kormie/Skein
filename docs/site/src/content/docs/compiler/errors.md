---
title: Structured Errors
description: How the Skein compiler reports errors in a machine-readable format.
---

## Error Design

Skein compiler errors are structured data, not just human-readable strings. Every error can serialize to JSON and includes fields designed for LLM consumption.

This is a core feature of the language -- when an AI agent generates Skein code that fails to compile, the structured error gives it enough information to understand and fix the issue automatically.

## Error Structure

```elixir
%Skein.Error{
  code: "E0001",                   # Stable error code
  severity: :error,                # :error or :warning
  message: "Unexpected token '}'", # Human-readable description
  location: %{                     # Where in the source
    file: "hello.skein",
    line: 5,
    col: 12
  },
  context: nil,                    # Optional surrounding code context
  fix_hint: "Expected expression after 'let x ='",  # What to do about it
  fix_code: nil,                   # Optional suggested code fix
  span: nil,                       # Exact extent of the problem (1-based, end-exclusive)
  edit_kind: nil                   # How to apply fix_code mechanically (nil = template)
}
```

## Fields

| Field | Type | Purpose |
|-------|------|---------|
| `code` | String | Stable identifier for the error category (e.g., `"E0001"`) |
| `severity` | Atom | `:error` (compilation fails) or `:warning` (compilation proceeds) |
| `message` | String | Human-readable description of the problem |
| `location` | Map | Source file, line number, column number |
| `context` | String or nil | The code around the error for display |
| `fix_hint` | String or nil | Suggestion for how to fix the issue |
| `fix_code` | String or nil | Exact code that would fix the issue |
| `span` | Map or nil | `%{start: %{line, col}, end: %{line, col}}` — the exact source extent (1-based; `end.col` exclusive) |
| `edit_kind` | Atom or nil | How to apply `fix_code` as a mechanical edit (see below) |

## Machine-Applicable Fixes

When `fix_code` is an exact edit (not an illustrative template), the error
also carries `span` and `edit_kind`, so any consumer — the LSP, `skein mcp`
clients, agents — can apply the fix without per-error-code logic:

| `edit_kind` | Application |
|-------------|-------------|
| `:replace` | Replace the spanned text with `fix_code` (empty `fix_code` deletes it) |
| `:insert_before` | Insert `fix_code` immediately before `span.start` |
| `:insert_after` | Insert `fix_code` immediately after `span.end` |
| `:insert_line` | Insert `fix_code` as a new line at `span.start.line`, indented to `span.start.col` |
| `:delete_line` | Delete the line(s) from `span.start.line` through `span.end.line` |

`Skein.Error.Edit.apply_fix/2` is the reference implementation of these
semantics. A `nil` `edit_kind` means the `fix_code` (if any) is a template
like `"fn name() -> Type { ... }"` — useful as a hint, not a verbatim edit.

## JSON Serialization

Errors serialize to JSON for tool integration:

```json
{
  "code": "W0001",
  "severity": "warning",
  "message": "Unused binding 'order'",
  "location": {
    "file": "hello.skein",
    "line": 5,
    "col": 3
  },
  "fix_hint": "Remove this binding or prefix with _ to indicate it is intentionally unused",
  "fix_code": "_order",
  "span": { "start": { "line": 5, "col": 7 }, "end": { "line": 5, "col": 12 } },
  "edit_kind": "replace"
}
```

## Error Flow

Errors are returned as lists throughout the pipeline:

```elixir
# Lexer error
{:error, [%Skein.Error{code: "E0001", message: "Unexpected character: #"}]}

# Parser error
{:error, [%Skein.Error{code: "E0001", message: "Expected 'module', got 'ident'"}]}

# Code generator error
{:error, [%Skein.Error{message: "Core Erlang compilation failed: ..."}]}
```

The compiler's `with` chain short-circuits on the first error list.

## Error Code Reference

All error codes are aligned with the language specification. Agents can rely on stable codes for automated error handling.

### Syntax Errors

| Code | Severity | Description |
|------|----------|-------------|
| E0001 | error | Unexpected token |
| E0002 | error | Invalid string: unterminated literal, expression inside `${...}` interpolation, empty interpolation (`${}`), or unterminated interpolation |
| E0003 | error | Invalid number literal (e.g. underscore grouping in a float: `1_000.5`) |

### Name Resolution Errors

| Code | Severity | Description |
|------|----------|-------------|
| E0010 | error | Undefined identifier |
| E0011 | error | Duplicate definition |
| E0016 | error | Cross-module function call (functions are module-private; expose a tool instead) |

### Capability Errors

| Code | Severity | Description |
|------|----------|-------------|
| E0012 | error | Missing capability for effect call |
| E0013 | reserved | Capability parameter mismatch |
| E0014 | error | Tool name not declared |
| E0015 | error | Duplicate tool short name |
| E0017 | error | Duplicate scoped capability declaration (`memory.kv`, `event.log`, `process.spawn`, `timer` allow one per module or agent) |

Example:

```json
{
  "code": "E0012",
  "severity": "error",
  "message": "Capability 'http.out' required but not declared. Effect calls to 'http' require this capability.",
  "location": {"file": "service.skein", "line": 5, "col": 5},
  "fix_hint": "Add a capability declaration to the module: capability http.out",
  "fix_code": "capability http.out"
}
```

The `fix_code` field is especially useful for LLM agents -- it provides the exact text to insert to resolve the error.

### Type Errors

| Code | Severity | Description |
|------|----------|-------------|
| E0020 | error | Type mismatch (including wrong argument counts or types for fn, stdlib, and effect calls, wrong-shape callbacks in higher-order slots, interpolation in string patterns, tool `implement` bodies vs the `Result[output, error]` contract, and provider bodies vs their declared return) |
| E0021 | warning | Non-exhaustive match |
| E0022 | error | Invalid `!` on non-Result |
| E0023 | error | Invalid `?` on non-Result, enclosing fn doesn't return Result, or the propagated error type is incompatible with the enclosing Result's error type |
| E0024 | error / warning | Unknown type name (error); non-exhaustive match on an enum, missing variant patterns (warning) |
| E0025 | error | Constraint annotation on wrong type |
| E0026 | error | Invalid named argument (unknown/duplicate name, positional after named, callee without named-argument support) |
| E0027 | error | Invalid guard expression (guards allow literals, bindings, field access, comparisons, boolean operators, and `+`/`-`/`*` arithmetic) |
| E0037 | error | Unverified type at a declared boundary: a value whose type is unknown, or whose branches produced incompatible types, cannot cross a declared fn return |
| E0038 | error | Provider contract violation: a scenario `implement` block whose signature does not match its capability's provider contract, or an `implement` under a capability with no provider contract |

### Agent Errors

| Code | Severity | Description |
|------|----------|-------------|
| E0030 | error | Invalid phase transition |
| E0031 | warning | Unreachable phase |
| E0032 | error | Phase handler missing |
| E0033 | error | `transition()` outside an agent, or in an agent that declares no `Phase` enum |
| E0034 | error | `suspend()` outside agent handlers |
| E0035 | error | `idempotent()` outside handler bodies |
| E0036 | error | `stop()` outside agent handlers |

### Supervisor Errors

| Code | Severity | Description |
|------|----------|-------------|
| E0040 | error | Invalid supervisor strategy |
| E0041 | error | Invalid `max_restarts` value |
| E0042 | warning | Supervisor has no children |

### Warnings

| Code | Severity | Description |
|------|----------|-------------|
| W0001 | warning | Unused binding |
| W0002 | warning | Unused capability |
| W0003 | warning | Unreachable code after `stop()` |
| W0004 | warning | Enum match covers only specific values of a variant (add a binding arm or wildcard) |

### Reserved Codes

E0013 (capability parameter mismatch) is reserved: the code is allocated and documented, but no compiler path constructs it yet. It keeps its meaning when first emitted — error codes are append-only.
