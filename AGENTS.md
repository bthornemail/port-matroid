# Repository Guidelines

## Project Structure & Module Organization
- `src/` contains the library code, organized under `src/Snapshot/` (e.g., `Snapshot.Decode`, `Snapshot.Encode`, `Snapshot.Types`).
- `test/` contains test suites and fixtures. `GoldenSpec.hs` and `PropertySpec.hs` are the entry points; `test/golden/` and `test/bad/` hold fixture data.
- `dev-docs/` contains developer notes and snapshots.
- `dist-newstyle/` is Cabal build output (generated; do not edit).

## Build, Test, and Development Commands
- `cabal build` builds the library defined in `port-matroid.cabal`.
- `cabal test` runs all test suites.
- `cabal test golden` runs golden tests only.
- `cabal test property` runs QuickCheck-based property tests.
- `cabal repl` starts a REPL for quick exploration.

## Coding Style & Naming Conventions
- Follow the existing style in `src/Snapshot/*.hs`: module-per-file, explicit exports, and small focused functions.
- Indentation is two spaces in current sources; keep that consistent.
- Module names use `Snapshot.*`; test modules use `*Spec` (e.g., `GoldenSpec`).
- Prefer total functions and explicit error types (see `Snapshot.Errors`).

## Testing Guidelines
- Golden tests validate binary formats against fixtures in `test/golden/` and `test/bad/`.
- Property tests use QuickCheck; keep generators deterministic where possible.
- Name new tests in `*Spec.hs` and add them to `port-matroid.cabal` if creating a new suite.

## Commit & Pull Request Guidelines
- The Git history does not yet establish a commit message convention. Use short, imperative messages (e.g., “Add CSPT validation”).
- PRs should include a clear summary, the tests run (`cabal test …`), and any new fixtures or format changes noted explicitly.

## Agent Notes
- Keep additions small and self-contained; this library is format- and validation-heavy, so prefer precise changes over sweeping refactors.
