# tool_call — tool definition plus `tool.call`

Ask the generator to write a complete Skein program from the public spec alone
that declares a tool, implements it, grants `capability tool.use(...)`, calls it
with `tool.call`, unwraps the `Result`, and reads a typed output field.

Release gate checks:
- generated source passes benchmark compile/load/run checks
- replayed golden source still converges under `mix skein.bench`
