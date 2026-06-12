# Market Research — Agent + Module + Tools Pattern

A properly architected example following the spec section 8.4 pattern (RefundService + RefundAgent).

## Architecture

```
┌─────────────────────────────┐     ┌──────────────────────────────┐
│  service.skein (module)     │     │  agent.skein (agent)         │
│                             │     │                              │
│  Tools:                     │     │  capability tool.use(...)    │
│    Research.SearchMarket    │◀────│  tool.call(Research.Search   │
│    Research.AnalyzeCompet.  │     │    Market, {...})            │
│    Research.GenerateSwot    │     │                              │
│                             │     │  Phases:                     │
│  HTTP endpoints:            │     │    Briefing → Gathering →    │
│    POST /research/start     │     │    Analyzing → Reporting →   │
│    GET  /research/status    │     │    Complete                  │
│    POST /research/resume    │     │                              │
│                             │     │  suspend() for human review  │
│  Supervisor: Main           │     │  No HTTP knowledge           │
└─────────────────────────────┘     └──────────────────────────────┘
```

## One File or Two — Both Shapes Work

The same program ships in two equivalent shapes:

- **Two files** — `service.skein` (module) + `agent.skein` (agent), one
  construct per file.
- **One file** — `single_file.skein`, with the agent nested inside the module
  (`module MarketResearch { ... agent MarketResearchAgent { ... } }`). The
  nested agent compiles to its own BEAM module
  (`Skein.Agent.MarketResearch.MarketResearchAgent`) and sees the module's
  types and capabilities in addition to its own.

## Key Design Principle

**Modules declare tools. Agents call tools.** The agent is pure workflow logic:
- It calls `tool.call(Research.SearchMarket, {...})` — it doesn't know the tool talks to an HTTP API
- It calls `suspend("reason")` — it doesn't know the module has a `/resume` endpoint
- The module provides the HTTP interface for humans and the tool implementations for the agent

## Phase Flow

1. **Briefing** — LLM checks if scope is focused enough. If too broad → `suspend()` for human refinement
2. **Gathering** — Calls `Research.SearchMarket` tool to get competitors, market size, trends
3. **Analyzing** — Calls `Research.AnalyzeCompetitor` tool for competitive analysis
4. **Reporting** — Calls `Research.GenerateSwot` tool to produce final SWOT analysis
5. **Complete** — Stops the agent

## Tools

| Tool | Purpose | Input | Output |
|------|---------|-------|--------|
| `Research.SearchMarket` | Search market data | topic, industry | competitors, market_size, trends |
| `Research.AnalyzeCompetitor` | Analyze competitor | competitor_name, market_context | strengths, weaknesses, positioning, strategy |
| `Research.GenerateSwot` | Generate SWOT | analysis_data, market_trends | strengths, weaknesses, opportunities, threats, summary |

## HTTP API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/research/start` | POST | Start research. Body: `ResearchRequest` |
| `/research/status` | GET | Check status |
| `/research/resume` | POST | Resume suspended agent. Body: `ResumeRequest` |

## How the Cross-Module Call Works at Runtime

Tools are the one cross-module seam in Skein (spec §3.1). When `skein build`,
`skein test`, or `skein run` loads a compiled module, every `tool` declaration
is registered into the runtime tool registry — that's what makes the agent's
`tool.call(Research.SearchMarket, {...})` resolve to the implement block in
`service.skein`. From Elixir, the same wiring is
`Skein.Runtime.Tool.register_module(mod)`.

The implement blocks post to `https://api.research.example`, a placeholder
host. The module deliberately declares **no** `http.out` capability, so at
runtime the outbound request is denied, each tool returns its declared error
(`SearchError` / `AnalysisError` / `SwotError`), and the agent takes its
suspend-for-human path — deterministically, with no network access. This is
the example's advertised failure flow, and it's executed end-to-end in CI
(`examples_test.exs`). To wire a real backend, point the URLs at your API and
declare `capability http.out("your-api-host")` in `service.skein`.

The Briefing phase calls `llm.chat`, which needs a configured LLM backend —
that phase is not executed in CI; the suite drives Gathering directly.

## Files

- `service.skein` — Module: tools, HTTP endpoints, supervisor, types
- `agent.skein` — Agent: pure workflow with tool.call and phase transitions
- `single_file.skein` — One-file variant with the agent nested inside the module
- `README.md` — This file
