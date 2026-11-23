# Open-source notes

This repo is public under the MIT license.

- Personal values (team ID, bundle ID, server address, Jax's text number) live only in `Config/Local.xcconfig`, which is not committed. `Config/Config.xcconfig` holds safe placeholders.
- No keys or passwords have ever been committed (checked 2026-11-21).
- Personal values were also scrubbed from every older commit (2026-11-23).
- The PC side of Jax (brain and orb server) is a separate project. To use this app you need your own Jax-compatible server that speaks `/ws/voice`.
