# Contributing to Skein

Skein is in **alpha**. Expect rough edges — and please report them. This page covers the
workflow; for environment setup, building, and running tests, see the
[development guide](https://kormie.github.io/Skein/contributing/development/).

## Ground rules

- **TDD is mandatory.** Tests land with (or before) the implementation — unit tests for every
  public function, property tests (StreamData/PropCheck) where the input space is wide.
- **One way to do things.** Before proposing a language feature, check the
  [spec](docs/SKEIN_SPEC.md) for an existing way to do it.
- **Errors are structured.** Compiler errors must be JSON-serializable with `fix_hint` and
  `fix_code` — that's a core feature, not polish.
- Run `mix format` and `mix test` before pushing. CI enforces formatting,
  `--warnings-as-errors` compilation, and the full suite.

## Filing issues

Use the issue forms (bug / feature / chore). New issues get the `status/triage` label
automatically; a maintainer then sets priority and milestone and removes the triage label.

| Label family | Meaning |
|---|---|
| `type/*` | `bug`, `feature`, `chore` |
| `area/*` | `compiler`, `runtime`, `cli`, `docs`, `ci`, `security` |
| `priority/*` | `p0` (drop everything) → `p2` (scheduled) |
| `status/triage` | Awaiting maintainer triage — the default for new issues |

## Milestones

- **Alpha Release** — the gate for the repo going public. Scope is the open Tier 1/2 roadmap
  items plus release automation.
- **Beta Release** — post-alpha hardening; triaged alpha feedback lands here unless it blocks
  alpha itself.

Milestones are defined in [`.github/milestones.json`](.github/milestones.json) and synced by a
workflow — edit that file rather than creating milestones by hand.

[`docs/ROADMAP.md`](docs/ROADMAP.md) is the canonical prioritized work list; every active
roadmap item links its tracking issue. If you change an item's scope, update both.

## Pull requests

- Branch from `main`; name branches `<topic>/<short-description>` (e.g. `compiler/named-args`).
- Commit messages: `[component] description` (e.g. `[parser] accept named arguments in calls`).
- One roadmap item / issue per PR. Reference it with `Closes #NN`.
- Update `docs/SKEIN_SPEC.md`, `docs/ARCHITECTURE.md`, and the docs site when behavior changes.

## Releases

A release is a PR that bumps `version` in `mix.exs` + `apps/skein_cli/mix.exs` and dates the
`CHANGELOG.md` section. After merge, pushing the annotated `v*` tag triggers the binary build
matrix and publishes the GitHub Release (automating the tag step is tracked in #100).

## License

By contributing to Skein, you agree that your contributions will be licensed
under the [MIT License](LICENSE).
