# Changelog

## [2026-11-21] Build 5: Jax on Apple Watch

### Added
- The watch app now ships inside the phone app. Tap Talk to Jax, dictate, and the answer shows as text with a tap on the wrist. Why through the phone: Apple does not let Tailscale run on a watch.
- The watch tries a second and third time if the phone link is still waking up.

### Verified
- Paired simulators (Apple Watch Series 11 and iPhone 17 Pro): the watch sent a question, the phone asked Jax, the answer came back in about 9 seconds.
- Not verified: a real watch, and the phone app being asleep in a pocket when the watch asks.

### Known limit
- If the phone app has only just opened, Jax's hello can end up on the end of the watch answer.

## [2026-11-21] Build 4: Messages, Mac, watch groundwork

### Added
- Messages screen (replaces History): the whole conversation as chat bubbles, oldest first, with a box to type in. While it is open Jax answers in text only. Why: Drey asked for an iMessage screen and for the chat history.
- "Text Jax in iMessage" in the Messages menu. Opens Jax's own number in the Messages app. Why: that thread is where Jax already lives in iMessage.
- Watch app code (`Watch/JaxWatchApp.swift`) and the phone relay (`Sources/WatchRelay.swift`). The watch sends your words to the phone, the phone asks Jax, the answer returns as text. Why through the phone: Apple does not let Tailscale run on a watch.

### Changed
- One shared Jax line for the whole app (`JaxClient.shared`), so the watch relay and the screen use the same connection.
- The hello Jax says on connect no longer gets glued to the front of the next answer.

### Shipped
- Build 1.0 (4) uploaded at 6:40 PM Eastern, status Testing in the internal TestFlight group "Drey".

### Not shipped
- The watch app is not in this build. Building it needs the watchOS simulator runtime (about 4 GB) and the Mac has about 8 GB free. The code compiles; it has never run on a watch.

### Mac
- No separate Mac app was needed. App Store Connect already offers this iPhone build to Apple silicon Macs, so it shows up in TestFlight on the Mac.

### Known limit
- Jax keeps one conversation for every device. If two devices ask at the same moment, the answers can mix.

### Verified
- Simulator: typed a message, got the answer as a bubble with no sound; menu; main screen still connects.
- Not verified: Messages on the real phone, the Mac install, anything on a watch.

## [2026-11-21] Build 3: history, connections, faster press

### Added
- History screen: what you said and what Jax answered, grouped by day, kept on the phone (newest 500). Why: Drey asked to see the chat history.
- Connections screen: opens the PC's connectors page inside the app. Why: Drey asked for a place to add connectors.
- One menu (top right) for History, Connections and Status.

### Changed
- The speech recogniser now starts off the main thread and is woken up when the app opens. Why: the first press felt slow because the press waited on it.
- Haptic taps are prepared ahead of time so the press tap lands with the finger.
- Release settle cut from 0.35 to 0.25 seconds.

### Measured
- From "sentence sent" to Jax's first sound: 3.0 s for a simple question, 8.5 s for one that needs memory. "Thinking" arrives in 0.2 s. So the wait is on the PC (brain plus voice), not in the app.

### Shipped
- Build 1.0 (3) uploaded at 6:19 PM Eastern, status Testing in the internal TestFlight group "Drey". Apple warned that from April 2027 uploads need the iOS 27 SDK (a newer Xcode).

### Known problem
- Connections shows "Couldn't reach Dreyvis". Why: the PC's `/api/connectors` returns a server error since the move from the VPS. The fix is on the PC, not in the app.

### Verified
- Simulator: menu, History with a real turn, Connections page loads zoom-locked, Status.
- Not verified: press speed on the real phone.

## [2026-11-21] Build 2: native rebuild

### Changed
- The talk screen is now fully native. Why: on a real phone build 1 (a web page in a frame) could be zoomed, the orb did not fit, and it often did not hear. Drey's words: "very janky".
- The app talks to Jax directly over `/ws/voice` instead of through the orb page. Why: the page's audio and the phone's microphone fought over the audio session. Nothing on the PC changed.

### Added
- Hold to talk. Why: Drey asked for it, and letting go sends at once instead of waiting for silence.
- Hands-free toggle, with the sentence gap cut from 1.2 to 0.8 seconds.
- Warm microphone with 0.4 seconds of pre-roll. Why: so the first word is never clipped when the button is pressed.
- Native orb that fits any screen and moves with your voice and Jax's.
- What Jax heard and what Jax says, as text on screen.
- Automatic reconnect with a visible Can't reach Jax state.
- Haptic taps on press, release and connect.

### Shipped
- Build 1.0 (2) uploaded and released to the internal TestFlight group "Drey" at 6:06 PM Eastern.

### Removed
- `SpeechBridge.swift` and `speech-polyfill.js` (the web page glue).

### Verified
- Simulator (iPhone 17 Pro): connects, a test sentence gets a spoken answer with the words shown, hold and release works through to "I didn't catch that" (no speech model in the Simulator), offline state and retry, status sheet.
- Not verified: real speech recognition and sound on the phone. Drey tests on TestFlight.

## [2026-11-21] Build 1

### Added
- First version of the Jax iPhone app: a native frame around the Jax orb page, so Jax can be tested away from the desk over Tailscale.
- Native speech bridge (`SpeechBridge.swift` plus `speech-polyfill.js`). Why: the orb listens through Chrome's speech API with two overlapping sessions, which an iPhone web view cannot do.
- Can't reach Jax screen with a 15 second limit and a Try again button. Why: a sleeping PC never refuses, it just hangs, and a blank page tells you nothing.
- Status sheet that opens the Jax `/dashboard` page. Why: it was one extra web view.
- Phone log lines (`[jax-ios]`) for each step between the page and Jax, message kinds only. Why: a silent failure on a phone is otherwise invisible.
- App icon drawn by `scripts/make-icon.swift` in the orb look (near-black, one sky blue).

### Fixed
- Microphone reported no signal on first start. Why: the audio engine was built before the audio session allowed recording. It is now built fresh on each start.
- Listening restarted about four times a second. Why: starting the audio engine posts a "route changed" notice, which was treated as a real route change.
- A busy microphone made the page retry ten times a second. Why: the error went straight to the page. The bridge now waits and retries on its own, slower each time.

### Shipped
- Build 1.0 (1) uploaded to App Store Connect as "Jax by Drey" (bundle ID `com.dreythomas.jax`, app 6837829723) and released to the internal TestFlight group "Drey". Why TestFlight and not a cable install: the phone runs iOS 27.2 and Xcode 26.6 cannot install onto it directly.

### Verified
- In the iPhone 17 Pro Simulator (iOS 26.5): orb loads, Jax's greeting plays, an injected sentence reaches Jax and the spoken answer comes back in about 5 seconds, the Can't reach Jax screen and Try again work, the status page loads.
- Not verified: real speech recognition (the Simulator has no speech model) and audio behaviour on a real iPhone.
