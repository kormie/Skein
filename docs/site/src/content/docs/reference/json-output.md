---
title: JSON Output (--json)
description: The stable, versioned JSON envelope emitted by skein compile, build, test, and trace under --json — the machine-readable agent contract for Skein tooling.
---

**Status:** stable from v1.0.0 onward (governed by [Stability & Versioning](/Skein/reference/stability/)).

`skein compile`/`skein check`, `skein build`, `skein test`, `skein run status`, `skein trace query`, and `skein event-store query` accept a
`--json` flag that replaces their human-readable output with a single
machine-readable JSON document on stdout. This is the contract coding agents
and CI scripts should parse — the plain text format is for humans and is not
a stable interface.

The flag is presentation-only: it never changes what a command *does*, only how
the result is reported. It may appear anywhere in the argument list
(`skein test --json`, `skein test --json ./project`, `skein test ./project --json`
are equivalent).

## The envelope

Every `--json` command prints exactly one JSON object, terminated by a single
newline, with the same three top-level keys:

```json
{
  "schema": "skein.<command>/v1",
  "ok": true,
  "data": { }
}
```

| Key | Type | Meaning |
|-----|------|---------|
| `schema` | string | Identifies the payload shape and its version: `skein.compile/v1`, `skein.build/v1`, `skein.test/v1`, `skein.run_status/v1`, `skein.trace/v1`, `skein.event_store/v1`. The `/vN` suffix is bumped only on a breaking change to `data`; additive fields do not bump it. |
| `ok` | boolean | The machine success signal. `true` means the command succeeded with nothing to fix. The process **exit code mirrors this**: `0` when `ok` is `true`, `1` otherwise — so a script can branch on either. |
| `data` | object | Command-specific payload, documented below. |

> Key **order** is not significant (this is JSON) — parse by key, never by
> position. New fields may be added to any `data` object within the same
> schema version, so ignore unknown keys.

### Top-level errors

A failure that prevents the command from producing its normal result — a bad
flag, a missing file, or an empty project — is reported as `ok: false` with a
single human-readable string:

```json
{ "schema": "skein.test/v1", "ok": false, "data": { "message": "No .skein files found in ./src/" } }
```

This is distinct from per-file or per-test failures (which appear inside the
normal `data` shape, described below). Detect a top-level error by the presence
of `data.message`.

## skein compile (the "check" command)

Compiles and checks a single `.skein` file. `ok` is `true` when there are no
errors (warnings do not affect `ok`).

```json
{
  "schema": "skein.compile/v1",
  "ok": true,
  "data": {
    "module": "Skein.User.Demo",
    "errors": [],
    "warnings": []
  }
}
```

| `data` field | Type | Notes |
|--------------|------|-------|
| `module` | string \| null | The compiled module's name, or `null` when compilation failed. |
| `errors` | array of [diagnostic](#diagnostic-objects) | Empty when `ok` is `true`. |
| `warnings` | array of [diagnostic](#diagnostic-objects) | Present whether or not compilation succeeded. |

## skein build

Compiles every `.skein` file under a project's `src/` tree. `ok` is `true` when
no file failed (`errors == 0`).

```json
{
  "schema": "skein.build/v1",
  "ok": true,
  "data": {
    "compiled": 2,
    "errors": 0,
    "modules": ["Skein.User.A", "Skein.User.B"],
    "failed": []
  }
}
```

| `data` field | Type | Notes |
|--------------|------|-------|
| `compiled` | integer | Count of modules that compiled. |
| `errors` | integer | Count of files that failed to compile. |
| `modules` | array of string | Names of compiled modules. |
| `failed` | array of `{ file, errors }` | Each entry has the source `file` and an array of [diagnostics](#diagnostic-objects). |

## skein test

Runs every test/scenario/golden across a project (compiling `src/` then `test/`
first). `ok` is `true` only when **no test failed and every file compiled**
(`failed == 0 and compile_errors == 0`).

```json
{
  "schema": "skein.test/v1",
  "ok": false,
  "data": {
    "total": 2,
    "passed": 1,
    "failed": 1,
    "files": 1,
    "compile_errors": 0,
    "compile_failed": [],
    "results": [
      { "description": "greets through the tool", "status": "passed", "kind": "scenario", "file": "test/main_test.skein" },
      {
        "description": "refund sends id header",
        "status": "failed",
        "kind": "scenario",
        "file": "test/refund_test.skein",
        "error": "expected status \"ok\", got \"error\"",
        "location": "test/refund_test.skein:14"
      }
    ]
  }
}
```

| `data` field | Type | Notes |
|--------------|------|-------|
| `total` / `passed` / `failed` | integer | Counts over the tests that ran. |
| `files` | integer | Number of files that contributed tests. |
| `compile_errors` | integer | Files that failed to compile and were therefore not tested. |
| `compile_failed` | array of `{ file, errors }` | Same shape as `build`'s `failed`. |
| `results` | array of [test result](#test-result-objects) | One per test/scenario/golden that ran. |

### Test result objects

| Field | Type | Notes |
|-------|------|-------|
| `description` | string | The test's declared description. |
| `status` | string | `"passed"` or `"failed"`. |
| `kind` | string | `"test"`, `"scenario"`, or `"golden"`. |
| `file` | string | Source file the test came from. |
| `error` | string | **Failures only.** The failure message — including the structured detail Skein's runner produces for a blocked live effect, an exhausted/mismatched replay trace, or an assertion mismatch. |
| `location` | string | **Failures with a known site only.** `file:line` of the failing assertion. |

## skein trace

Reports recent trace spans from the runtime trace store. `ok` is always `true`
on a successful read (an empty trace is success with `count: 0`).

```json
{
  "schema": "skein.trace/v1",
  "ok": true,
  "data": {
    "count": 2,
    "spans": [
      { "kind": "http", "method": "get", "url": "/refunds", "status": 200, "outcome": "ok", "duration_us": 1500 },
      { "kind": "llm", "method": "chat", "url": "anthropic", "outcome": "ok", "duration_us": 3200 }
    ]
  }
}
```

Each span is projected down to a **fixed, stable field set** — `kind`,
`method`, `url`, `status`, `outcome`, `duration_us` — so arbitrary recorded
payloads never leak into (or break) the contract. Fields a given span does not
carry are omitted, so every span kind renders without a fixed key set; only
`kind` is effectively always present.

| Field | Type | Notes |
|-------|------|-------|
| `kind` | string | Span kind: `http`, `llm`, `tool`, `memory`, `store`, `uuid`, `instant`, ... |
| `method` | string | e.g. `get`/`post` for http, `chat`/`json` for llm. Omitted when absent. |
| `url` | string | Request URL or backend name. Omitted when absent. |
| `status` | integer | HTTP status code. Omitted when absent. |
| `outcome` | string | `ok` / `err`. Omitted when absent. |
| `duration_us` | integer | Span duration in **microseconds**. Omitted when absent. |

## Diagnostic objects

Compiler errors and warnings (in `compile`/`build`) serialize as Skein's
structured [`Skein.Error`](/Skein/compiler/errors/) — the same JSON the
[MCP server](/Skein/editor/mcp-server/) returns. Every diagnostic carries:

| Field | Type | Notes |
|-------|------|-------|
| `code` | string | Stable diagnostic code, e.g. `E0020`, `W0002`. |
| `severity` | string | `"error"` or `"warning"`. |
| `message` | string | Human-readable description. |
| `location` | `{ file, line, col }` | Where the diagnostic applies. |
| `span` | `{ start, end }` \| null | End-exclusive source span when known. |
| `context` | string \| null | The offending source line, when available. |
| `fix_hint` | string \| null | A human-readable suggestion. |
| `fix_code` | string \| null | Suggested replacement text. |
| `edit_kind` | string \| null | Machine-applicability discriminator (`replace`, `insert_before`, ...); `null` means `fix_code` is a template, not a literal edit. |

A top-level error reason that is not a structured diagnostic (a usage or
filesystem message) is reported as a minimal `{ "message": "..." }` object in
the same `errors` array, so `data.errors` is uniformly a list of objects.

## TUI / interactivity

`--json` is mutually independent from the interactive seam. `trace` also accepts
`--interactive` (opt into a TTY front-end where one exists) and `--no-tui` /
`SKEIN_NO_TUI` (force plain). None of these change `--json` output: a JSON
request always produces the byte-for-byte envelope above, never a TUI. MCP, LSP,
and any non-TTY stdout likewise never route through a TUI.


## Runtime inspection commands

`skein run status --json [project-dir]` compiles the service and returns
`skein.run_status/v1` without opening the HTTP listener. Its payload includes
`state`, `phase`, `module`, `modules`, `modules_count`, `port`, `persist`,
`project_dir`, `handlers[]`, and `supervisors[]`. Handler entries carry stable
inspection fields such as `module`, `handler`, `phase`, `source`, `method`,
`path`, and `capability` when known.

`skein trace query --json` is an alias for `skein trace --json`. Trace spans and
EventStore events may include the cross-cutting fields `module`, `handler`,
`tool`, `agent`, `name`, `phase`, `capability`, `effect_span`, `error_code`, and
`fix_hint` in addition to the effect-specific span fields.

`skein event-store query --json [--last n] [--kind kind] [--event name]
[--stream stream]` returns `skein.event_store/v1` with `count` and `events[]`.
Events are projected to a JSON-safe stable field set, so private runtime values
such as pids are never part of the contract.

### End-to-end agent example

An agent can run `skein event-store query --json --kind tool --last 1`, read the
failed event's `module`, `tool`, `phase`, `effect_span`, `error_code`, and
`fix_hint`, and map the failure back to the source Skein construct. For example,
a tool event with `module: "Refunds"`, `tool: "Refunds.Create"`,
`phase: "execute"`, `effect_span.start.line: 42`, and
`error_code: "E_CAPABILITY_DENIED"` points the agent at the
`tool.call(Refunds.Create, ...)` expression in `Refunds` and tells it to add the
missing `capability tool.use(Refunds.Create)` declaration.
