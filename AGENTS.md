# AGENTS.md: start here (any AI)

You are working on **Jax for iPhone**: a native SwiftUI voice app (plus an Apple Watch app) that talks to Jax, a personal AI assistant running on a home PC.

## Read first

1. [README.md](README.md): what it does, how it connects, how to build and ship.
2. [CHANGELOG.md](CHANGELOG.md): every build and why each change was made.
3. [docs/diagrams/architecture.mmd](docs/diagrams/architecture.mmd): the system map.

## The system in one line

`Phone (this app) -> Tailscale -> orb server on the PC (:8340, /ws/voice) -> Jax brain (:8642, WSL distro "vps")`

The PC side (orb server, Jax brain) is **not** in this repo. This repo is the phone and watch app only. The app speaks the same `/ws/voice` messages the desktop orb page uses, so changing the app never requires PC changes.

## Rules

- Swift and SwiftUI only. Native screens, never a web page in a frame for the main UI.
- `project.yml` is the source of truth. Edit it, then `xcodegen generate`. `Jax.xcodeproj` is generated and not committed.
- Every TestFlight upload needs a higher `CURRENT_PROJECT_VERSION` in `project.yml`.
- Every meaningful change gets a line in `CHANGELOG.md` with the why.
- No secrets in the repo. There are none today; keep it that way.
- Test on a real iPhone for speech. The Simulator has no speech model (use the `-JaxSay` launch argument there).
- Plain-English labels in the UI. No em-dashes in any text.

## Open source

Personal values live in `Config/Local.xcconfig` (never commit it). See [OPEN-SOURCE.md](OPEN-SOURCE.md).
