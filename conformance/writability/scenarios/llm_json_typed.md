# llm_json_typed — typed `llm.json[T]`

Ask the generator to write a complete Skein program from the public spec alone
that declares an output record type, calls `llm.json[T]`, propagates
`LlmError`, and validates/uses fields from the typed result.

Release gate checks:
- generated source passes benchmark compile/load/run checks
- replayed golden source still converges under `mix skein.bench`
