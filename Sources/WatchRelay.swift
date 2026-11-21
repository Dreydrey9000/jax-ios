import UIKit
import WatchConnectivity

/// The phone's half of Jax on the watch: words come in from the wrist,
/// go to Jax over the phone's Tailscale line, and the answer goes back as text.
/// iOS wakes this app in the background when the watch sends a message.
final class WatchRelay: NSObject, WCSessionDelegate {
    static let shared = WatchRelay()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let words = message["say"] as? String else { replyHandler(["text": ""]); return }
        Task { @MainActor in
            // Ask iOS for time to finish: Jax can take several seconds.
            var pass = UIBackgroundTaskIdentifier.invalid
            pass = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(pass) }
            let answer = await JaxClient.shared.ask(words)
            replyHandler(["text": answer])
            UIApplication.shared.endBackgroundTask(pass)
        }
    }
}
