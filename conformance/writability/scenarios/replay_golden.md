# replay_golden — deterministic replay corpus

The benchmark records live generations in `conformance/writability/recordings.json`.
The release gate replays those golden generations against the current compiler;
no network or LLM call is allowed in replay mode.

Release gate checks:
- every recorded task converges to green
- the checked-in first-try quality floor does not collapse
