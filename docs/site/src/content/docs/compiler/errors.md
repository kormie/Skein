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
  code: "E001",                    # Stable error code
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
| `code` | String | Stable identifier for the error category (e.g., `"E001"`) |
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
  "code": "E001",
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
{:error, [%Skein.Error{code: "E001", message: "Unexpected character: #"}]}

# Parser error
{:error, [%Skein.Error{code: "E002", message: "Expected 'module' keyword"}]}

# Code generator error
{:error, [%Skein.Error{message: "Core Erlang compilation failed: ..."}]}
```

The compiler's `with` chain short-circuits on the first error list.

## Error Code Reference

### Lexer/Parser Errors

| Code | Severity | Description |
|------|----------|-------------|
| E0001 | error | Core Erlang compilation failed |
| E0002 | error | Unexpected token / parse error |

### Name Resolution Errors (Phase 2)

| Code | Severity | Description |
|------|----------|-------------|
| E0010 | error | Unknown identifier |
| E0011 | error | Unknown type reference |
| E0012 | error | Wrong function call arity |

### Type Errors (Phase 2)

| Code | Severity | Description |
|------|----------|-------------|
| E0020 | error | Type mismatch (return type, match arm types) |
| E0021 | error | Operator type error (wrong operand types) |
| E0024 | warning | Non-exhaustive match |
| E0025 | error | Invalid constraint annotation |

### Capability Errors (Phase 3)

| Code | Severity | Description |
|------|----------|-------------|
| E0012 | error | Missing capability for effect call |

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

### Agent Error Codes

| Code | Severity | Description |
|------|----------|-------------|
| E0030 | error | Invalid phase transition |
| E0031 | warning | Unreachable phase |
| E0032 | error | Phase handler missing |
| E0033 | error | `transition()` called outside agent handler |
| E0034 | error | `suspend()` called outside agent handler |
| E0035 | error | `idempotent()` called outside handler body |

### Future Error Codes

- **Store errors:** Missing `store.table` capability (Phase 5)
