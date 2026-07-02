---
title: Agent-Writability Benchmark
description: How Skein measures its central pitch — an LLM agent writing new Skein from the docs, converging to a compiling program through structured diagnostics — and the measured trend over recorded live runs.
---

Skein's central pitch is that the language is co-optimized for humans to read
and LLM agents to write (design principle P6). The agent-writability benchmark
measures that instead of asserting it.

## The measured trend

![Agent-writability benchmark: tasks-green and first-try compile rates over recorded live runs](/Skein/writability-history.svg)

Each point is one recorded live run of the full suite. The raw data lives in
[`conformance/writability/history.jsonl`](https://github.com/kormie/Skein/blob/main/conformance/writability/history.jsonl);
the chart regenerates whenever a live run is recorded.

## How it works

For each of twelve fixed tasks spanning the language surface — pure functions,
records with `Option`, `Result` flows, enums and `match`, stdlib callbacks,
string interpolation, tools, HTTP handlers, the typed store, agents, LLM
effects, and scenario capability environments — the harness runs a
generate-compile-fix loop:

1. Ask a code-generating model for a complete Skein module. The generation
   context is exactly the [agent primer](/Skein/reference/agent-primer/) that
   `skein new` scaffolds into every project as `AGENTS.md`.
2. Compile it and collect the structured diagnostics.
3. Mechanically apply every machine-applicable fix (`span` + `edit_kind` +
   `fix_code`), the way the LSP and MCP consumers do.
4. Feed the remaining diagnostics (JSON) back to the model and iterate to
   green, up to a cap.

The report carries the P6 quality metrics: **first-try compile rate**, **mean
iterations to green**, how much work the machine-applicable fixes did, and
which diagnostics failed to converge. A non-converging diagnostic is treated
as a compiler bug — the first live run surfaced several
([#336](https://github.com/kormie/Skein/issues/336)), and fixing them took the
suite from 10/12 to 12/12 green.

## Deterministic by default

Every live run records the raw generations to
`conformance/writability/recordings.json`. CI and release-readiness run in
**replay mode**: the recorded generations re-run through the *current*
compiler with no LLM calls, so the metrics are deterministic and a recorded
solution that stops compiling is a caught regression, exactly like the
dogfood corpus.

```bash
# Replay the recordings (deterministic, no network):
mix skein.bench

# Re-measure live and refresh recordings + history + chart
# (needs ANTHROPIC_API_KEY):
mix skein.bench -- --live
```

A live run can also be triggered on demand from the repository's
**Writability Bench** GitHub Actions workflow; the refreshed recordings land
through a normal pull request, pinned by the replay test.
