# Changelog

## Unreleased

### Changed

- Upgraded the Zig toolchain requirement from Zig 0.15.2 to Zig 0.16.0.
- Removed the unused `libxev` Zig package declaration; `zig/build.zig.zon` now declares no external Zig package dependencies.
- Routed Makai runtime I/O, HTTP, filesystem, random, stdio, timing, and networking internals through Zig 0.16 `std.Io`-based APIs while preserving Makai-owned wrapper boundaries for future backend evolution.
- Split and documented the expanded Zig unit test matrix used by CI, including the Makai CLI and agent subgroups.

### Migration Notes

- See [`docs/zig-0.16.0-downstream-migration.md`](docs/zig-0.16.0-downstream-migration.md) for downstream source migration guidance for Makai Zig consumers.
