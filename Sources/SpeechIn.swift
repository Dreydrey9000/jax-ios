import AVFoundation
import Speech
import os

private let log = Logger(subsystem: "com.dreythomas.jax", category: "ears")

/// The iPhone's ears: microphone -> Apple speech recognition -> text.
///
/// The microphone stays warm the whole time the app is open, and the last
/// fraction of a second is always kept. So when you press the button, the
/// start of your first word is already there and nothing gets clipped.
///
/// Two ways to listen:
/// - Hold: listen from press to release. Letting go sends at once, no waiting.
/// - Hands-free: listen all the time. A pause of `sentenceGap` ends the sentence.
final class SpeechIn {
    /// Hands-free only. Shorter cuts people off mid-thought, longer feels slow.
    private let sentenceGap: TimeInterval = 0.8
    /// How long to wait after release for the recogniser's last correction.
    private let releaseGrace: TimeInterval = 0.25
    /// Audio kept from before the press, in seconds.
    private let preRoll: Double = 0.4

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onEvent: ((String) -> Void)?
    var onProblem: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest? // guarded by lock
    private var recent: [AVAudioPCMBuffer] = []                 // guarded by lock
    private var recentFrames: AVAudioFrameCount = 0             // guarded by lock
    private var rawLevel: Float = 0                             // guarded by lock
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var wanted = false       // the app is open and wants the microphone warm
    private var running = false      // the engine is actually up
    private var continuous = false   // hands-free listening is on
    private var holding = false
    private var heard = ""
    private var gapTimer: Timer?
    private var graceTimer: Timer?
    private var failures = 0
    private var everHeard = false
    private lazy var onDevice = recognizer?.supportsOnDeviceRecognition ?? false
    private var startedAt = Date.distantPast
    private var retryDelay: TimeInterval = 1
    private var observers: [NSObjectProtocol] = []
    /// Starting a recognition pass can take a few hundred milliseconds the first
    /// time. It runs here so a button press never waits on it.
    private let work = DispatchQueue(label: "jax.ears", qos: .userInitiated)
    private var modelLoaded = false

    /// 0...1, how loud the room is right now. Drives the orb while you talk.
    var level: Double {
        lock.lock()
        let rms = rawLevel
        lock.unlock()
        return max(0, min(1, Double(rms) * 9))
    }

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            // Starting our own engine also posts this. Only a change to an engine
            // that is already up is a real route change (headphones in or out).
            guard let self, (note.object as AnyObject?) === self.engine,
                  Date().timeIntervalSince(self.startedAt) > 1 else { return }
            self.restart("audio route changed")
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.restart("interruption ended") }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: commands

    /// Ask for permission once, then keep the microphone running.
    func warmUp() {
        guard !wanted else { return }
        wanted = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async { self?.refuse("Speech Recognition is off for Jax. Turn it on in Settings.") }
                return
            }
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async {
                    guard let self, self.wanted else { return }
                    if ok { self.startEngine() } else { self.refuse("The microphone is off for Jax. Turn it on in Settings.") }
                }
            }
        }
    }

    func shutDown() {
        wanted = false
        continuous = false
        holding = false
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setListening(_ on: Bool) {
        guard continuous != on else { return }
        continuous = on
        guard !holding else { return }
        if on { newPass() } else { endPass() }
    }

    func beginHold() {
        holding = true
        graceTimer?.invalidate()
        newPass(withPreRoll: true)
        onEvent?("hold began")
    }

    /// Finger lifted. Give the recogniser a moment to settle its last word, then send.
    func endHold() {
        guard holding else { return }
        holding = false
        lock.lock()
        request?.endAudio()
        lock.unlock()
        let mine = generation
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: releaseGrace, repeats: false) { [weak self] _ in
            guard let self, mine == self.generation else { return }
            self.finish(self.heard)
        }
    }

    func cancelHold() {
        holding = false
        graceTimer?.invalidate()
        endPass()
        if continuous { newPass() }
    }

    // MARK: engine

    private func refuse(_ why: String) {
        wanted = false
        onEvent?("refused: " + why)
        onProblem?(why)
    }

    private func startEngine() {
        guard wanted, !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Play and record together, out of the loudspeaker, AirPods allowed.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true)

            // Built fresh every time: an engine made before the session could
            // record remembers a microphone with no signal and never recovers.
            engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "Jax", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
            }
            let keep = AVAudioFrameCount(format.sampleRate * preRoll)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.feed(buffer, keep: keep)
            }
            engine.prepare()
            try engine.start()
            running = true
            retryDelay = 1
            startedAt = Date()
            log.info("microphone warm")
            onEvent?("microphone warm")
            if continuous, !holding { newPass() } else { loadModel() }
        } catch {
            // Busy for a moment (a call ending). Wait and try again, slower each time.
            log.error("microphone would not start: \(error.localizedDescription, privacy: .public)")
            onEvent?("microphone would not start: \(error.localizedDescription)")
            stopEngine()
            let wait = retryDelay
            retryDelay = min(retryDelay * 2, 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.startEngine() }
        }
    }

    private func stopEngine() {
        endPass()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        running = false
        lock.lock()
        recent.removeAll()
        recentFrames = 0
        rawLevel = 0
        lock.unlock()
    }

    private func restart(_ why: String) {
        guard wanted else { return }
        log.info("restarting microphone: \(why, privacy: .public)")
        stopEngine()
        startEngine()
    }

    /// Wake the speech model up before the first press, so the first press is as fast as the tenth.
    private func loadModel() {
        guard !modelLoaded, !holding, !continuous else { return }
        modelLoaded = true
        newPass()
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, mine == self.generation, !self.holding, !self.continuous else { return }
            self.endPass()
        }
    }

    /// Runs on the audio thread, many times a second.
    private func feed(_ buffer: AVAudioPCMBuffer, keep: AVAudioFrameCount) {
        var rms: Float = 0
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            rms = (sum / Float(buffer.frameLength)).squareRoot()
        }
        lock.lock()
        rawLevel = rms
        recent.append(buffer)
        recentFrames += buffer.frameLength
        while recentFrames > keep, let first = recent.first, recentFrames - first.frameLength >= keep {
            recentFrames -= first.frameLength
            recent.removeFirst()
        }
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    // MARK: recognition

    private func endPass() {
        gapTimer?.invalidate()
        gapTimer = nil
        graceTimer?.invalidate()
        generation += 1
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
        heard = ""
    }

    /// One pass = one sentence. The microphone keeps running between passes.
    private func newPass(withPreRoll: Bool = false) {
        endPass()
        guard running, let recognizer, recognizer.isAvailable else { return }
        let mine = generation

        let fresh = SFSpeechAudioBufferRecognitionRequest()
        fresh.shouldReportPartialResults = true
        fresh.addsPunctuation = true
        // On the phone when the phone can: faster, private, and no time cap.
        fresh.requiresOnDeviceRecognition = onDevice
        lock.lock()
        if withPreRoll { recent.forEach(fresh.append) }
        request = fresh
        lock.unlock()

        // The microphone is already feeding `fresh`. Only the recogniser start is slow, so it goes off the main thread.
        work.async { [weak self] in
          let started = recognizer.recognitionTask(with: fresh) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, mine == self.generation else { return }
                if let result {
                    self.failures = 0
                    self.everHeard = true
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty, text != self.heard {
                        self.heard = text
                        self.onPartial?(text)
                    }
                    if result.isFinal {
                        self.finish(text)
                    } else if !self.holding, self.continuous, !text.isEmpty {
                        self.gapTimer?.invalidate()
                        self.gapTimer = Timer.scheduledTimer(withTimeInterval: self.sentenceGap, repeats: false) { [weak self] _ in
                            guard let self, mine == self.generation else { return }
                            self.finish(self.heard)
                        }
                    }
                } else if let error = error as NSError? {
                    self.failed(error, mine: mine)
                }
            }
          }
          DispatchQueue.main.async {
              guard let self, mine == self.generation else { started.cancel(); return }
              self.task = started
          }
        }
    }

    private func failed(_ error: NSError, mine: Int) {
        // Code 1110 is "nobody spoke". A quiet room, not a fault.
        if error.code == 1110 {
            if holding || graceTimer?.isValid == true { return } // the release timer reports it
            if continuous { newPass() }
            return
        }
        failures += 1
        log.error("recogniser error \(error.domain, privacy: .public) \(error.code): \(error.localizedDescription, privacy: .public)")
        onEvent?("recogniser error \(error.domain) \(error.code)")
        if onDevice, !everHeard, failures >= 2 {
            onDevice = false
            failures = 0
            onEvent?("on-device recognition would not start, using Apple's servers")
        }
        if failures > 6 {
            failures = 0
            #if !targetEnvironment(simulator)
            onProblem?("Speech recognition is not working right now.")
            #endif
            return
        }
        guard continuous || holding else { return }
        let wait = min(0.3 * pow(2, Double(failures)), 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, mine == self.generation, self.continuous || self.holding else { return }
            self.newPass()
        }
    }

    private func finish(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        endPass()
        log.info("sentence done (\(said.count) characters)")
        onEvent?("sentence done, \(said.count) characters")
        onFinal?(said)
        if continuous, !holding { newPass() }
    }
}
