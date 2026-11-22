# Open-source notes

This repo is public under the MIT license.

- Personal values (team ID, bundle ID, server address, Jax's text number) live only in `Config/Local.xcconfig`, which is not committed. `Config/Config.xcconfig` holds safe placeholders.
- No keys or passwords have ever been committed (checked 2026-11-21).
- Older commits (builds 1 to 7) still contain the home PC's private Tailscale address and Jax's text number. The address only works from inside that private network.
- The PC side of Jax (brain and orb server) is a separate project. To use this app you need your own Jax-compatible server that speaks `/ws/voice`.
