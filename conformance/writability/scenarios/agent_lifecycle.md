# agent_lifecycle — single-agent workflow

Ask the generator to write a complete Skein program from the public spec alone
that defines one top-level agent with explicit phases, legal transitions, and a
terminal state that calls `stop()`.

Release gate checks:
- generated source passes benchmark compile/load/run checks
- replayed golden source still converges under `mix skein.bench`
