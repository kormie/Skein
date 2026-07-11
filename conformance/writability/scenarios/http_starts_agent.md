# http_starts_agent — HTTP handler that starts an agent

Ask the generator to write a complete Skein program from the public spec alone
with an HTTP handler that accepts a request, validates typed input, starts an
agent workflow, and returns an HTTP response naming the started workflow.

Release gate checks:
- generated source passes benchmark compile/load/run checks
- replayed golden source still converges under `mix skein.bench`
