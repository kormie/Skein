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

## Files

- `service.skein` — Module: tools, HTTP endpoints, supervisor, types
- `agent.skein` — Agent: pure workflow with tool.call and phase transitions
- `README.md` — This file
