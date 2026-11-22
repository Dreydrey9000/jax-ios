# Before making this repo public

The repo is private. It holds no keys or passwords, but a few personal values are hardcoded. Swap them before flipping it public.

| Value | Where | Replace with |
|---|---|---|
| Private Tailscale address of the home PC | `Sources/JaxApp.swift`, `README.md` | A settings screen, or a placeholder like `https://your-jax-host:8443/` |
| Jax's text-message phone number | `Sources/History.swift` (`jaxTextLine`) | A setting, or remove the "Text Jax in iMessage" item |
| Apple team ID `ABCDE12345` and bundle ID `com.dreythomas.jax` | `project.yml`, `README.md` | Placeholders each builder fills in |
| PC name `YOUR-PC` | `README.md` | "your PC" |

Also needed:

- A license file (MIT is the common pick for apps like this).
- A short "run your own Jax" note, since the PC side is a separate project.
- Rewriting git history is **not** needed: no secrets were ever committed (checked 2026-11-21).
