# capability_environment — scenario capability environment

Ask the generator to write a complete Skein program from the public spec alone
that tests an effectful tool in a `scenario` whose nested capability envelope
provides the complete offline environment needed by the tool.

Release gate checks:
- generated source passes benchmark compile/load/run checks
- replayed golden source still converges under `mix skein.bench`
