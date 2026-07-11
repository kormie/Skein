#!/usr/bin/env python3
"""Regenerate docs/generated/skein-language-pack.md from canonical sources."""
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
out = repo / "docs/generated/skein-language-pack.md"
out.parent.mkdir(parents=True, exist_ok=True)

def read(path: str) -> str:
    return (repo / path).read_text()

parts = ["""# Skein Language Pack (Generated)

> Generated artifact for AI agents. This single file is intended to be loaded as the complete working language context for writing, reviewing, compiling, and testing Skein programs.

**Context-window budget:** this pack must remain below **128K approximate tokens**. The executable size gate uses 4 bytes/token and therefore enforces a maximum of **524,288 bytes**.

## How to use this pack

1. Read the quick index and CLI commands below.
2. Treat the embedded `SKEIN_SPEC.md` as normative for grammar, keywords, type rules, capabilities/effects, stdlib signatures, testing/scenario syntax, and diagnostics.
3. Use the frozen registries for machine-checkable inventories (keywords, diagnostics, effect ABI).
4. Use canonical examples as copyable starting points; every complete `skein` fence in this pack is drift-checked by the compiler test suite.

## Quick index

- Complete grammar: see embedded spec §2–§3.
- Reserved and contextual keywords: see embedded spec §2.3 and frozen `keywords.json`.
- Type system rules: see embedded spec §4.
- Standard library signatures: see embedded spec §5.
- Capability/effect ABI: see embedded spec §6 and frozen `effect_abi.json`.
- Diagnostics table and structured diagnostic ABI: see embedded spec §7 and frozen `diagnostics.json`.
- Testing/scenario/golden syntax: see embedded spec §3.10 and §8.
- Canonical examples: see the examples section near the end of this pack.
- Build/test/run/check commands: see the CLI section below.

## CLI commands for build/test/run/check

From the repository root during compiler development:

```bash
mix deps.get
mix compile
mix test
mix test apps/skein_compiler/test/skein/conformance/docs_fences_test.exs
mix test apps/skein_compiler/test/skein/language_pack_test.exs
mix skein.compile examples/hello.skein
mix skein.build path/to/project
mix skein.test path/to/project
mix skein.run path/to/project
mix skein.trace path/to/trace.jsonl
mix docs
```

From an installed Skein binary in a Skein project:

```bash
skein new my-service
skein compile src/main.skein
skein build
skein test
skein run
skein trace traces/run.jsonl
skein lsp
skein mcp
skein completions zsh
skein help
```

---

""",
read("docs/SKEIN_SPEC.md"),
"""

---

# Frozen machine-readable registries

## Reserved/contextual keywords (`conformance/freeze/keywords.json`)

```json
""", read("conformance/freeze/keywords.json"), """
```

## Capability/effect ABI (`conformance/freeze/effect_abi.json`)

```json
""", read("conformance/freeze/effect_abi.json"), """
```

## Diagnostics registry (`conformance/freeze/diagnostics.json`)

```json
""", read("conformance/freeze/diagnostics.json"), """
```

---

# Canonical compiling examples

## Hello module

```skein
""", read("examples/hello.skein"), """
```

## Standard library demo

```skein
""", read("examples/stdlib_demo.skein"), """
```

## HTTP capability example

```skein
""", read("examples/hello_http.skein"), """
```

## Agent and tool example

```skein
""", read("examples/refund_agent.skein"), """
```
"""]

out.write_text("".join(parts))
print(f"wrote {out.relative_to(repo)}")
