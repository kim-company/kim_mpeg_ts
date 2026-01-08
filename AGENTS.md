# Repository Guidelines

## Project Structure & Module Organization
- `lib/` contains the Elixir source, primarily under `lib/mpeg/ts/` (e.g., `packet.ex`, `demuxer.ex`, `muxer.ex`).
- `test/` mirrors `lib/` with ExUnit tests in `test/mpeg/ts/` plus helpers in `test/support/`.
- `test/data/` holds binary TS fixtures used by tests.
- `docs/` includes PDF specifications referenced by the implementation.
- `mix.exs` and `mix.lock` define project metadata and dependencies.

## Build, Test, and Development Commands
- `mix deps.get` installs dependencies.
- `mix compile` compiles the project.
- `mix test` runs the full ExUnit suite.
- `mix test --cover` runs tests with coverage reporting.
- `mix docs` generates API documentation.
- `mix dialyzer` performs type analysis (Dialyzer).
- `mix format` formats Elixir source and tests.

`mise.toml` pins tool versions; use `mise` if you need matching local runtimes.

## Coding Style & Naming Conventions
- Use standard Elixir formatting (2-space indentation) and run `mix format`.
- Module names follow `MPEG.TS.*` and live in matching paths under `lib/mpeg/ts/`.
- Test files use the `_test.exs` suffix and mirror module structure.

## Testing Guidelines
- Framework: ExUnit (built into Elixir).
- Prefer tests that align with existing patterns in `test/mpeg/ts/`.
- Reuse fixtures from `test/support/factory.ex` and binary data from `test/data/`.
- Add coverage for new parsing/serialization paths and error handling modes.

## Commit & Pull Request Guidelines
- Commit messages are short, imperative, and unprefixed (e.g., "Fix compiler warning", "Bump version").
- Open PRs against `main` and include a concise description of behavior changes.
- Link related issues when applicable and note any new fixtures or spec references added.

## Architecture Overview (Optional Context)
- Parsing and serialization are layered: packets (`MPEG.TS.Packet`) → tables (PAT/PMT/PSI) → PES aggregation → demux/mux entry points.
- Keep changes localized to the relevant layer and update tests at the same level.
