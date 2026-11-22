import Foundation
import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "com.dreythomas.jax", category: "client")

/// A number the orb reads every frame. Not published on purpose: a level that
/// changes 30 times a second would redraw the whole screen instead of just the orb.
final class Meter {
    var value: Double = 0
}

enum Phase: Equatable {
    case connecting
    case offline(String)
    case ready
    case hearing
    case thinking
    case searching // thinking has gone on a while: Jax is looking something up
    case speaking
}

/// The app's brain stem: one live line to Jax on the closet PC.
///
/// Phone -> Jax: the words you said. Jax -> phone: what it is doing
/// (thinking, speaking) and its voice as small MP3 pieces.
@MainActor
final class JaxClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published private(set) var notice = ""
    @Published private(set) var hint = ""
    @Published private(set) var searchLabel = "" // what Jax is looking through, when the PC says
    @Published var handsFree = UserDefaults.standard.bool(forKey: "handsFree") {
        didSet {
            UserDefaults.standard.set(handsFree, forKey: "handsFree")
            syncListening()
        }
    }

    let meter = Meter()
    private let voice = AudioOut()
    private let ears = SpeechIn()
    private var socket: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var retryDelay: TimeInterval = 1
    private var retryWork: DispatchWorkItem?
    private var openTimer: Timer?
    private var pingTimer: Timer?
    private var meterTimer: Timer?
    private var lastInterimAt = Date.distantPast
    private var holding = false
    private var holdStartedAt = Date.distantPast
    private var awaitingAnswer = false
    private var hintWork: DispatchWorkItem?
    private let thump = UIImpactFeedbackGenerator(style: .medium)
    private let tick = UIImpactFeedbackGenerator(style: .light)
    let history = HistoryStore()
    private var turnID: UUID?

    /// One Jax for the whole app, so the watch relay and the screen share one line.
    static let shared = JaxClient()
    private var active = false                 // the app is on screen
    private var askDone: ((String) -> Void)?   // a watch question waiting for its answer

    /// Words from the watch. Wakes the line if the app is asleep, returns Jax's answer as text.
    func ask(_ text: String) async -> String {
        let onScreen = active
        if socket == nil { connect() }
        var waited = 0
        while socket == nil || phase == .connecting || isOffline, waited < 40 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        guard socket != nil, !isOffline, phase != .connecting else {
            return "Can't reach Jax. Open Tailscale on the phone."
        }
        if !onScreen { quiet = true } // a phone in a pocket should not start talking
        final(text)
        let answer = await withCheckedContinuation { (wait: CheckedContinuation<String, Never>) in
            askDone = { wait.resume(returning: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.finishAsk() }
        }
        if !onScreen, !active {
            quiet = false
            pause()
        }
        return answer
    }

    private func finishAsk() {
        guard let done = askDone else { return }
        askDone = nil
        done(reply.isEmpty ? "Jax did not answer in time." : reply)
    }

    override init() {
        super.init()
        voice.onPlayed = { [weak self] utt, idx in self?.send(["type": "played", "utt": utt, "idx": idx]) }
        ears.onPartial = { [weak self] text in self?.partial(text) }
        ears.onFinal = { [weak self] text in self?.final(text) }
        ears.onEvent = { [weak self] text in self?.send(["type": "mic", "text": "ios: " + text]) }
        ears.onProblem = { [weak self] text in self?.flash(text, seconds: 6) }
    }

    // MARK: lifecycle

    func start() {
        active = true
        ears.warmUp()
        thump.prepare()
        tick.prepare()
        connect()
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let target = self.phase == .speaking ? self.voice.level : (self.phase == .hearing ? self.ears.level : 0)
                self.meter.value += (target - self.meter.value) * 0.35
            }
        }
    }

    func pause() {
        active = false
        guard askDone == nil else { return } // the watch is mid-question; ask() hangs up after
        holding = false
        ears.shutDown()
        voice.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        retryWork?.cancel()
        pingTimer?.invalidate()
        openTimer?.invalidate()
        meterTimer?.invalidate()
    }

    func retryNow() {
        retryDelay = 1
        connect()
    }

    // MARK: connection

    private func connect() {
        retryWork?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        if case .offline = phase {} else { phase = .connecting }

        var request = URLRequest(url: JaxHost.voiceSocket, timeoutInterval: 10)
        // The server only talks to its own page. Same address, so same origin.
        request.setValue(JaxHost.origin, forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        listen(on: task)

        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.socket === task, self.phase == .connecting || self.isOffline else { return }
                self.dropped("No answer after 10 seconds.", from: task)
            }
        }
    }

    private var isOffline: Bool {
        if case .offline = phase { return true }
        return false
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            guard webSocketTask === socket else { return }
            log.info("connected")
            openTimer?.invalidate()
            retryDelay = 1
            phase = .ready
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            send(["type": "mic", "text": "ios: app connected"])
            pingTimer?.invalidate()
            pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let live = self.socket else { return }
                    live.sendPing { error in
                        guard let error else { return }
                        Task { @MainActor in self.dropped(error.localizedDescription, from: live) }
                    }
                }
            }
            syncListening()
            #if DEBUG
            if let line = UserDefaults.standard.string(forKey: "JaxSay") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.final(line) }
            }
            #endif
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let ws = task as? URLSessionWebSocketTask else { return }
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            let why = status >= 400 ? "The PC answered, but Jax is not running (error \(status))."
                : (error?.localizedDescription ?? "The connection closed.")
            dropped(why, from: ws)
        }
    }

    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .failure(let error):
                    self.dropped(error.localizedDescription, from: task)
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.listen(on: task)
                }
            }
        }
    }

    private func dropped(_ why: String, from task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        log.error("connection lost: \(why, privacy: .public)")
        socket = nil
        task.cancel(with: .goingAway, reason: nil)
        openTimer?.invalidate()
        pingTimer?.invalidate()
        voice.stop()
        ears.setListening(false)
        holding = false
        phase = .offline(why)
        // Keep trying quietly. The owner should not have to babysit a reconnect.
        let wait = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func send(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Jax -> phone

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }
        switch type {
        case "audio":
            guard let b64 = msg["data"] as? String, let mp3 = Data(base64Encoded: b64),
                  let utt = (msg["utt"] as? NSNumber)?.intValue, let idx = (msg["idx"] as? NSNumber)?.intValue else { return }
            if let words = msg["text"] as? String, !words.isEmpty { addReply(words) }
            if holding || quiet { // you are talking over it, or reading the answer instead
                awaitingAnswer = false
                send(["type": "played", "utt": utt, "idx": idx])
                return
            }
            awaitingAnswer = false
            setPhase(.speaking)
            voice.enqueue(mp3, utt: utt, idx: idx)
        case "stop":
            voice.stop()
            if !holding { setPhase(.ready) }
        case "drop_queued":
            voice.dropQueued()
        case "status":
            guard !holding else { return }
            switch msg["state"] as? String {
            case "thinking", "compacting":
                // Jax has picked the sentence up. Anything shown before this
                // (the hello Jax says on connect) is not the answer.
                if awaitingAnswer { reply = "" }
                awaitingAnswer = false
                setPhase(.thinking)
            case "searching":
                awaitingAnswer = false
                searchLabel = (msg["label"] as? String) ?? ""
                setPhase(.searching)
            case "speaking":
                awaitingAnswer = false
                setPhase(.speaking)
            case "idle":
                if !awaitingAnswer {
                    setPhase(.ready)
                    if !reply.isEmpty { finishAsk() }
                    break
                }
                // An "idle" from before the sentence landed. Wait for Jax to pick
                // it up, but never sit on "Thinking" for ever if it decides not to answer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, self.awaitingAnswer, self.phase == .thinking || self.phase == .searching else { return }
                    self.awaitingAnswer = false
                    self.setPhase(.ready)
                }
            default: break
            }
        case "text":
            if let words = msg["text"] as? String { addReply(words) }
        case "notice":
            notice = (msg["text"] as? String) ?? ""
        default:
            break
        }
    }

    private func addReply(_ words: String) {
        reply = reply.isEmpty ? words : reply + " " + words
        if let turnID { history.setReply(reply, for: turnID) }
    }

    private func setPhase(_ next: Phase) {
        guard phase != next, !isOffline, phase != .connecting || next == .ready else { return }
        phase = next
        syncListening()
    }

    /// Hands-free listens whenever Jax is not the one talking. Hold-to-talk listens only while held.
    private func syncListening() {
        guard !holding else { return }
        ears.setListening(handsFree && !quiet && (phase == .ready || phase == .hearing))
    }

    /// The Messages screen is open: answers are read, not spoken, and the microphone rests.
    private(set) var quiet = false
    func setQuiet(_ on: Bool) {
        quiet = on
        if on {
            voice.stop()
            send(["type": "hush"])
        }
        syncListening()
    }

    /// A typed message. Same road as a spoken one.
    func type(_ text: String) {
        guard socket != nil, !isOffline, phase != .connecting else {
            flash("Can't reach Jax right now.", seconds: 4)
            return
        }
        final(text)
    }

    // MARK: phone -> Jax

    func pressDown() {
        guard !holding, socket != nil, !isOffline, phase != .connecting else { return }
        holding = true
        holdStartedAt = Date()
        thump.impactOccurred()
        thump.prepare()
        if phase == .speaking || voice.isPlaying {
            voice.stop()
            send(["type": "hush"])
        }
        hint = ""
        heard = ""
        phase = .hearing
        ears.beginHold()
    }

    func pressUp() {
        guard holding else { return }
        holding = false
        tick.impactOccurred()
        tick.prepare()
        if Date().timeIntervalSince(holdStartedAt) < 0.3 {
            ears.cancelHold()
            phase = .ready
            flash("Hold the button while you talk.", seconds: 3)
            syncListening()
            return
        }
        ears.endHold() // calls back into final(_:) within half a second
    }

    func stopTalking() {
        voice.stop()
        send(["type": "hush"])
        setPhase(.ready)
    }

    private func partial(_ text: String) {
        guard holding || handsFree else { return }
        heard = text
        if phase == .ready { phase = .hearing }
        guard Date().timeIntervalSince(lastInterimAt) > 0.25 else { return }
        lastInterimAt = Date()
        send(["type": "interim", "text": text])
    }

    private func final(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else {
            if phase == .hearing { phase = .ready }
            if !handsFree { flash("I didn't catch that. Hold and try again.", seconds: 4) }
            syncListening()
            return
        }
        heard = said
        reply = ""
        turnID = history.add(you: said)
        awaitingAnswer = true
        phase = .thinking // shown at once; Jax confirms a moment later
        searchLabel = ""
        // Still thinking after 2.5 seconds means a lookup. Show it, even if the PC does not say so.
        let turn = turnID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.turnID == turn, self.phase == .thinking else { return }
            self.phase = .searching
        }
        send(["type": "transcript", "text": said, "isFinal": true])
        syncListening()
    }

    private func flash(_ text: String, seconds: TimeInterval) {
        hint = text
        hintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hint = "" }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
