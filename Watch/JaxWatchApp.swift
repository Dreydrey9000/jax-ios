import SwiftUI
import WatchConnectivity
import WatchKit

/// Jax on the wrist.
///
/// A watch cannot join Tailscale (Apple does not allow it), so the watch never
/// talks to the PC itself. It hands your words to the Jax app on the iPhone,
/// the phone asks Jax, and the answer comes back here as text.
/// ponytail: text answers plus a tap on the wrist. Add Jax's voice on the watch
/// when the phone relay has proven itself.
final class Phone: NSObject, ObservableObject, WCSessionDelegate {
    @Published var said = ""
    @Published var answer = ""
    @Published var busy = false

    override init() {
        super.init()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func ask(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !busy else { return }
        said = words
        answer = ""
        busy = true
        WCSession.default.sendMessage(["say": words], replyHandler: { reply in
            DispatchQueue.main.async {
                self.answer = (reply["text"] as? String) ?? ""
                self.busy = false
                WKInterfaceDevice.current().play(.success)
            }
        }, errorHandler: { _ in
            DispatchQueue.main.async {
                self.answer = "Can't reach your iPhone. Keep it nearby with Tailscale on."
                self.busy = false
                WKInterfaceDevice.current().play(.failure)
            }
        })
    }
}

@main
struct JaxWatchApp: App {
    var body: some Scene {
        WindowGroup { WatchScreen() }
    }
}

struct WatchScreen: View {
    @StateObject private var phone = Phone()
    private let sky = Color(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // The system's own dictation screen: tap, speak, Done.
                    TextFieldLink(prompt: Text("Say something to Jax")) {
                        Label("Talk to Jax", systemImage: "mic.fill").frame(maxWidth: .infinity)
                    } onSubmit: { phone.ask($0) }
                    .buttonStyle(.borderedProminent)
                    .tint(sky)
                    .foregroundStyle(.black)
                    .disabled(phone.busy)

                    if phone.said.isEmpty {
                        Text("Tap, speak, and Jax answers here.").foregroundStyle(.secondary)
                    } else {
                        Text(phone.said).font(.footnote).foregroundStyle(.secondary)
                    }
                    if phone.busy {
                        ProgressView("Thinking").frame(maxWidth: .infinity)
                    } else if !phone.answer.isEmpty {
                        Text(phone.answer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Jax")
        }
    }
}
