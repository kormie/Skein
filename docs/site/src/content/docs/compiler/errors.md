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
  fix_code: nil                    # Optional suggested code fix
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

## JSON Serialization

Errors serialize to JSON for tool integration:

```json
{
  "code": "E0001",
  "severity": "error",
  "message": "Unexpected token '}'",
  "location": {
    "file": "hello.skein",
    "line": 5,
    "col": 12
  },
  "fix_hint": "Expected expression after 'let x ='"
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
| E0020 | error | Type mismatch (including wrong argument counts for fn, stdlib, and effect calls, and interpolation in string patterns) |
| E0021 | warning | Non-exhaustive match |
| E0022 | error | Invalid `!` on non-Result |
| E0023 | error | Invalid `?` on non-Result (or enclosing fn doesn't return Result) |
| E0024 | error / warning | Unknown type name (error); non-exhaustive match on an enum, missing variant patterns (warning) |
| E0025 | error | Constraint annotation on wrong type |
| E0026 | error | Invalid named argument (unknown/duplicate name, positional after named, callee without named-argument support) |
| E0027 | error | Invalid guard expression (guards allow literals, bindings, field access, comparisons, boolean operators, and `+`/`-`/`*` arithmetic) |

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
