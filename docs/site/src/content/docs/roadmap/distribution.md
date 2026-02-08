---
title: Distribution
description: Next steps for packaging Skein so others can use it without the source repository.
---

## Current State

Skein currently requires cloning the source repository and running via Mix. There are no standalone binaries, installable packages, or release artifacts. To use Skein today:

```bash
git clone <repo>
cd Skein
mix deps.get
mix skein.build my_project/
mix skein.run my_project/ --port 4000
```

`skein build` now supports writing compiled `.beam` files to disk with the `--output` flag:

```bash
mix skein.build my_project/ --output _build/beam
```

This page documents the planned work to make Skein fully distributable.

## Goal

A developer should be able to install Skein, create a project, and deploy a compiled artifact -- without ever cloning the compiler source.

## 1. Standalone CLI Binary

The highest-priority distribution artifact is a self-contained `skein` binary that bundles the compiler, runtime, and BEAM. A user would download a single file and run `skein new`, `skein build`, `skein test`, and `skein run` directly.

### Approach: Burrito

[Burrito](https://github.com/burrito-elixir/burrito) wraps an OTP release into a self-extracting archive for Linux, macOS, and Windows. It bundles the Erlang runtime so the user doesn't need OTP installed.

**Steps:**

1. Add `burrito` as a dependency in the root `mix.exs`
2. Configure target platforms (Linux x86_64, macOS ARM64, macOS x86_64)
3. Add a `releases:` section to `mix.exs` pointing at `skein_cli` as the entry point
4. Create a `Skein.CLI.Main` module with a `main/1` entry point that dispatches to existing CLI functions
5. Build per-platform binaries in CI and attach them to GitHub releases

### Alternative: Escript

An escript is simpler but requires the user to have Erlang/OTP installed. This could serve as an interim solution while the Burrito-based binary is developed.

**Steps:**

1. Add `escript: [main_module: Skein.CLI.Main]` to `skein_cli/mix.exs`
2. Implement `Skein.CLI.Main.main/1` to parse argv and dispatch
3. Build with `mix escript.build`
4. Distribute the resulting `skein` executable

## 2. OTP Releases for Skein Projects

`skein build` currently compiles `.skein` files into in-memory BEAM modules. To deploy a Skein project, the build step needs to produce a standalone OTP release that can be copied to a server and started.

**Planned output structure:**

```
_build/rel/my_service/
├── bin/my_service          # Start/stop script
├── lib/
│   ├── my_service-0.1.0/   # Compiled .beam files
│   ├── skein_runtime-0.1.0/
│   └── ...
└── releases/
    └── 0.1.0/
        ├── sys.config
        └── vm.args
```

**Steps:**

1. ~~Update `skein build` to write `.beam` files to disk instead of only loading them into the running VM~~ Done
2. Generate a minimal Mix project on the fly that depends on `skein_runtime` and includes the compiled modules
3. Run `mix release` against the generated project to produce a self-contained OTP release
4. ~~Support `skein build --output ./release` to specify the output path~~ Done

### Docker Images

Once OTP releases work, producing Docker images is straightforward:

1. Provide a `Dockerfile.skein` template in `skein new` scaffolding
2. Multi-stage build: compile in a builder image, copy the release into a minimal runtime image
3. The resulting image needs only the OS and ERTS -- not Elixir, Mix, or the Skein compiler

## 3. Hex.pm Packages

Publishing the Skein compiler and runtime to Hex.pm would allow Elixir developers to embed Skein compilation in their own projects (e.g., compiling `.skein` files at build time inside a Phoenix app).

**Three packages:**

| Package | Purpose |
|---------|---------|
| `skein_compiler` | Lexer, parser, analyzer, codegen |
| `skein_runtime` | Agent behaviour, HTTP, memory, LLM, store, trace |
| `skein` | Meta-package pulling both plus CLI Mix tasks |

**Steps:**

1. Add `package:` metadata (description, licenses, links) to each app's `mix.exs`
2. Add `docs:` configuration for ExDoc
3. Ensure all dependencies are on Hex.pm (not Git-only)
4. Publish with `mix hex.publish`

## 4. GitHub Releases and CI

Automate artifact creation in CI so every tagged version produces downloadable binaries and a release.

**Steps:**

1. Add a GitHub Actions workflow triggered by version tags (`v*`)
2. Build Burrito binaries for each target platform
3. Build the escript as a fallback
4. Attach all artifacts to the GitHub release
5. Generate a changelog from commit history

## 5. Installer Script

For quick onboarding, provide a curl-pipe-bash installer:

```bash
curl -fsSL https://skeinlang.dev/install.sh | bash
```

The installer would detect the user's OS/architecture, download the appropriate binary from the latest GitHub release, and place it on `$PATH`.

## Priority Order

| Priority | Artifact | Rationale |
|----------|----------|-----------|
| 1 | Escript | Fastest to implement; unblocks Elixir-native users |
| 2 | ~~`skein build` writes `.beam` to disk~~ | Done — `skein build --output` writes `.beam` files |
| 3 | OTP release generation | Enables standalone server deployment |
| 4 | Burrito binaries | Enables zero-dependency install for all users |
| 5 | Hex.pm packages | Enables embedding Skein in Elixir projects |
| 6 | Docker template | Enables container-based deployment |
| 7 | CI release pipeline | Automates everything above |

## Prerequisites

All prerequisites for distribution work have been completed:

- ~~**Enum variant matching** needs to land in codegen (the last gap in the core language)~~ **Done.** Enum variants compile to tagged tuples (e.g., `{:charge, 100}`) and pattern matching in `match` expressions correctly destructures them. Both simple atom variants and variants with fields are supported.
- ~~**Supervisor declarations** should be at least minimally implemented for agent pool use cases~~ **Done.** Supervisors can be declared with `child`, `strategy:`, and `max_restarts:` directives. Parsing, analysis (including validation), and codegen (exposing `__supervisors__/0` metadata) are implemented.
- ~~**`skein build`** needs to be extended to write `.beam` files to a target directory~~ **Done.** `skein build <project> --output <dir>` compiles all `.skein` files and writes `.beam` files to the specified directory. The compiler also exposes `Compiler.compile_to_binary/1` for programmatic use.
