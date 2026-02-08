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

## Future Error Categories

Phase 2+ will add error categories for:

- **Type errors:** "Expected String, got Int at line 12, col 5"
- **Capability errors:** "Capability 'http.out' required but not declared" with `fix_code: "capability http.out(\"api.example.com\")"`
- **Transition errors:** "Invalid transition from Done to Analyze" (for agent phase graphs)
- **Exhaustiveness warnings:** "Non-exhaustive match: missing pattern 'Deleted'"
