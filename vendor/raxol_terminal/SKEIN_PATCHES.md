# Vendored raxol_terminal 2.4.0 — Skein patches

Vendored from the `raxol_terminal` 2.4.0 hex package
(https://github.com/DROOdotFOO/raxol, MIT — LICENSE.md retained) and used
as a `path:`/`override: true` dependency until the changes land upstream.
Tracking: kormie/Skein#171 (PR #239 recorded the G1 spike evidence).

## Patch 1 — stdin reader: OTP raw mode instead of user_drv tracing

`lib/raxol/terminal/driver.ex` (`start_stdin_reader/1`)

Upstream acquired input in `-noshell` mode by calling `user_drv:start_shell`
with a noop shell — which prints the Erlang banner and a
`*** ERROR: Shell process terminated!` notice into the TUI — and then
`:erlang.trace/3`-intercepting the user_drv reader's sends. On macOS the
interception delivers nothing: the TUI renders but never receives a key
(verified on macOS aarch64 / ghostty, 2026-06-12; `q` dead, Ctrl-C then
kills the VM with mouse reporting left enabled and an orphaned BEAM).

Replaced with the documented OTP path: `shell:start_interactive({noshell,
raw})` (OTP 26+; Skein's floor is 28) plus a linked reader process doing
plain `:io.get_chars/3` and forwarding `{:raw_input, data}` — the message
shape the driver already consumes. The reader pid is stored in
`io_terminal_state.input_reader`, which `TermboxLifecycle.cleanup_terminal/1`
already kills on teardown (upstream stored the *OTP* `:user_drv_reader`
pid there and killed that instead).

The now-unreferenced `{:trace, ...}` handle_manager_info clauses are left
in place to keep this diff minimal.

## Patch 2 — drop the vendored termbox2_nif subtree and its NIF build

- Deleted `lib/termbox2_nif/` (vendored C sources **plus a full embedded
  mix project including compiled deps of elixir_make**). Two effects in
  the upstream package:
  1. the embedded elixir_make sources compile into `raxol_terminal.app`,
     and `mix release` then fails with "Duplicated modules" against the
     real elixir_make app;
  2. Burrito's per-target NIF recompile runs `make` at the dep root
     (elixir_make's `make_cwd` is not honored by Burrito), which fails —
     and the NIF's `.so` never reaches `priv/` anyway, so
     `Raxol.Terminal.Driver.backend()` is always `:io_terminal` here.
- `mix.exs`: removed the Unix-only `:elixir_make` compiler configuration
  and dependency, and the dev-only tooling deps. Pure Elixir on every
  platform; the driver's compile-time backend check selects
  `:io_terminal` everywhere, which is the only backend Skein ships.

## Upstreaming

Patch 1 is the upstream PR candidate (macOS input fix + no banner inside
the TUI). Patch 2 maps to two upstream packaging fixes: don't package the
embedded termbox2_nif mix project (or at least its `deps/`), and install
the NIF into `priv/` if it is meant to ship. Drop this vendored copy and
return to the hex package once releases containing them exist.
