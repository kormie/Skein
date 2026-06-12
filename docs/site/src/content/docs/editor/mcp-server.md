---
title: MCP Server
description: Register the Skein MCP server with Claude Code, Cursor, and other coding agents for spec lookup, docs search, and structured compile checks.
---

The Skein CLI ships an [MCP](https://modelcontextprotocol.io) (Model Context
Protocol) server that gives coding agents on-demand access to the language
spec and the compiler's structured diagnostics — without stuffing the whole
spec into the agent's base prompt.

```bash
skein mcp
```

The server speaks JSON-RPC 2.0 over stdio (newline-delimited messages) and
needs no network access: the language spec is embedded in the binary at build
time.

## Registering

### Claude Code

```bash
claude mcp add skein -- skein mcp
```

Or add it to `.mcp.json` in your project root to share it with your team:

```json
{
  "mcpServers": {
    "skein": {
      "command": "skein",
      "args": ["mcp"]
    }
  }
}
```

### Cursor

Add to `.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (global):

```json
{
  "mcpServers": {
    "skein": {
      "command": "skein",
      "args": ["mcp"]
    }
  }
}
```

Other MCP-capable tools (Codex, Windsurf, Zed, ...) follow the same pattern:
configure a stdio server with command `skein` and arguments `["mcp"]`.

## Tools

### `skein_spec_lookup`

Fetches a named section of the language specification. Pass a section number
or a title fragment:

```json
{ "section": "6.4" }
{ "section": "agents" }
```

If nothing matches, the result lists every available section title, so an
agent can self-correct in one round trip.

### `skein_docs_search`

Case-insensitive search across the spec corpus. Returns each matching section
title with the matching lines:

```json
{ "query": "idempotent" }
```

### `skein_compile_check`

Compiles a `.skein` file — or every file under a project's `src/` when given
a directory (checking `src/` and `test/`, matching `skein test`'s
discovery) — and returns the compiler's structured JSON diagnostics
directly. Warnings are included; `ok` reflects errors only:

```json
{ "path": "src/main.skein" }
```

```json
{
  "ok": false,
  "files_checked": 1,
  "errors": [
    {
      "code": "E0012",
      "severity": "error",
      "message": "Missing capability declaration for http.out",
      "location": { "file": "src/main.skein", "line": 3, "col": 13 },
      "fix_hint": "Add the capability declaration to the module",
      "fix_code": "capability http.out(\"example.com\")",
      "span": { "start": { "line": 2, "col": 3 }, "end": { "line": 2, "col": 3 } },
      "edit_kind": "insert_line"
    }
  ],
  "warnings": [
    {
      "code": "W0002",
      "severity": "warning",
      "message": "Unused capability 'store.table' — declared but never exercised",
      "location": { "file": "src/main.skein", "line": 4, "col": 3 },
      "fix_hint": "Remove this capability declaration if it is no longer needed",
      "fix_code": ""
    }
  ]
}
```

Skein's compiler errors carry `fix_hint` and `fix_code` precisely so agents
can apply fixes mechanically — MCP delivers them without shelling out and
parsing CLI output. When the fix is an exact edit, `span` (1-based,
end-exclusive) and `edit_kind` say where and how to apply it without any
per-error-code logic: `replace` the spanned text with `fix_code`,
`insert_before`/`insert_after` it at the span's edges, `insert_line` it as
a new line indented to the span's start column, or `delete_line` the
spanned lines. A `null` `edit_kind` marks `fix_code` as an illustrative
template rather than a verbatim edit.

## Related

- `skein new` scaffolds an `AGENTS.md` primer (and a `CLAUDE.md` pointer)
  into every project; `skein agents` refreshes it after a toolchain upgrade.
- Published agent docs: [llms.txt](https://kormie.github.io/Skein/llms.txt),
  [llms-small.txt](https://kormie.github.io/Skein/llms-small.txt),
  [llms-full.txt](https://kormie.github.io/Skein/llms-full.txt).
