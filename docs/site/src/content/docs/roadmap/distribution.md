---
title: Distribution
description: Packaging Skein so others can use it without the source repository.
---

## Current State

Skein ships as **standalone binaries** via Burrito for Linux x86_64, Linux ARM64, macOS x86_64, and macOS ARM64, published automatically by CI on every `v*` tag (along with the VS Code extension `.vsix` and a checksums file). Users download a single `skein` binary and can immediately create, build, test, and run projects — no Erlang, Elixir, or Mix required.

```bash
./skein new my_project
./skein build my_project
./skein test my_project
./skein run my_project --port 4000
```

`skein build` also supports writing compiled `.beam` files to disk:

```bash
./skein build my_project --output _build/beam
```

This page documents both what's done and the remaining work to make Skein fully distributable.

---

## 1. Standalone CLI Binary ✅

A self-contained `skein` binary that bundles the compiler, runtime, and BEAM.

### Burrito Distribution (Implemented)

[Burrito](https://github.com/burrito-elixir/burrito) wraps an OTP release into a self-extracting archive for Linux, macOS, and Windows. It bundles the Erlang runtime so the user doesn't need OTP installed.

**Implementation:**

- `burrito` (~> 1.5) added as a dependency of `skein_cli`
- Release configured in root `mix.exs` with four targets: Linux x86_64, Linux ARM64, macOS x86_64, macOS ARM64
- `Skein.CLI.Main` module implements the `Application` behaviour and dispatches subcommands via `Burrito.Util.Args.argv/0`
- In release mode (Mix not available), the entry point reads args and routes to `compile`, `new`, `build`, `test`, `run`, `trace`, `version`, and `help` commands
- In dev mode, the existing Mix aliases continue to work as before

**Building standalone binaries:**

```bash
# Build for the current platform
MIX_ENV=prod mix release skein

# Build for a specific target
BURRITO_TARGET=linux MIX_ENV=prod mix release skein
BURRITO_TARGET=macos_arm MIX_ENV=prod mix release skein
```

Binaries are written to `burrito_out/`.

---

## 2. OTP Releases for Skein Projects

`skein build` compiles `.skein` files and can write `.beam` files to disk. To deploy a Skein project as a standalone server, the build step needs to produce a full OTP release.

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

1. ~~Update `skein build` to write `.beam` files to disk~~ ✅ Done
2. Generate a minimal Mix project on the fly that depends on `skein_runtime` and includes the compiled modules
3. Run `mix release` against the generated project to produce a self-contained OTP release
4. ~~Support `skein build --output ./release`~~ ✅ Done

### Docker Images

Once OTP releases work, producing Docker images is straightforward:

1. Provide a `Dockerfile.skein` template in `skein new` scaffolding
2. Multi-stage build: compile in a builder image, copy the release into a minimal runtime image
3. The resulting image needs only the OS and ERTS — not Elixir, Mix, or the Skein compiler

---

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

---

## 4. GitHub Releases and CI ✅

Implemented: `.github/workflows/build.yml` triggers on version tags (`v*`), builds Burrito binaries for all four targets plus the VS Code `.vsix`, and publishes a GitHub Release with the artifacts, checksums, and auto-generated release notes. (Automating the *tag* step itself — tagging green merges that bump the version — is tracked in [#100](https://github.com/kormie/Skein/issues/100).)

---

## 5. Installer Script

For quick onboarding, provide a curl-pipe-bash installer:

```bash
curl -fsSL https://skeinlang.dev/install.sh | bash
```

The installer would detect the user's OS/architecture, download the appropriate binary from the latest GitHub release, and place it on `$PATH`.

---

## Priority Order

| Priority | Artifact | Status |
|----------|----------|--------|
| 1 | `skein build` writes `.beam` to disk | ✅ Done |
| 2 | Burrito standalone binaries | ✅ Done (Linux x86_64/ARM64, macOS x86_64/ARM64) |
| 3 | CI release pipeline | ✅ Done (binaries + `.vsix` + checksums on every `v*` tag) |
| 4 | OTP release generation | Enables standalone server deployment |
| 5 | Hex.pm packages | Enables embedding Skein in Elixir projects |
| 6 | Docker template | Enables container-based deployment |

## Prerequisites

All prerequisites for distribution work have been completed:

- ✅ **Enum variant matching** — Enum variants compile to tagged tuples and pattern matching correctly destructures them
- ✅ **Supervisor declarations** — Supervisors with `child`, `strategy:`, and `max_restarts:` are parsed, analyzed, and generate metadata
- ✅ **`skein build --output`** — Writes compiled `.beam` files to a target directory
