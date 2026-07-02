# Contributing to Skein

Skein is **pre-1.0**, in active development toward a smaller, stronger first stable release (see the [roadmap reset](docs/ROADMAP.md), 2026-06-15). v1.0.0-rc.1 was tagged but **GA is not imminent** and the spec is **not** finally frozen — the soundness, scenario-testing (capability environments), observability, and conformance work in flight may still change surface. Please report anything that contradicts the spec or docs. This page covers the
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

- **v0.4.0 — Truth & Soundness** — the active gate (Wave A truth reset + Wave B analyzer/codegen
  soundness — B1–B6 complete and source-verified 2026-07-02 — plus the Wave B residue).
- **v0.5.0 — Runtime Contract & Dogfood** — next (Wave C effect-ABI/structured-error/schema/store/
  EventStore honesty, C1–C6 + supervisor wiring #325; Wave D continuous dogfood gate).
- **v1.0.0-rc.2 — True release candidate** — cut only when every 1.0 blocker is green; no feature
  work. (The conditional v0.6.0 canonical-substrate milestone was retired 2026-07-02 when #300
  resolved as Alternative B — the substrate items live in v1.1.)
- **v1.0.0 Release** — GA, after rc.2 soaks (not imminent).
- **v1.1: Hardening & Language** / **v1.2: Interop & Agent Workflows** / **Future: Platform** —
  the post-1.0 backlog, in priority order.
- **v0.1 Alpha Release**, **v0.2 Beta Release**, and **v1.0.0-rc Release** — closed; they gated
  taking the repo public, the post-alpha hardening wave, and tagging v1.0.0-rc.1.

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
`CHANGELOG.md` section. Merging it with green CI auto-tags `v<version>`, builds the binary
matrix, and publishes the GitHub Release (`release.yml` → `build.yml`); there is no manual
tag step.

Before merging a bump PR, dispatch the **Release Readiness** workflow (Actions → Release
Readiness) with the intended version for a full dry run — tests, the release gates, real
binaries for all targets, a CLI smoke test against the built binary, and the docs build —
without creating any tag or release. In a Claude Code session, `/release-readiness <version>`
runs the complementary local pass: the same gates plus an agent audit of every docs page,
spec section, and example.

What a version number is allowed to change — stability classes for every
public surface, release cadence, and the deprecation policy — is defined in
[docs/STABILITY.md](docs/STABILITY.md). Check it before merging anything that
touches public surface.

## License

By contributing to Skein, you agree that your contributions will be licensed
under the [MIT License](LICENSE).
