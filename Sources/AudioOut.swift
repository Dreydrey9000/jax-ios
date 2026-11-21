import AVFoundation
import os

private let log = Logger(subsystem: "com.dreythomas.jax", category: "voice")

/// Jax's voice. The PC sends the answer as small MP3 pieces so the first words
/// can play while the rest is still being made. Each piece is confirmed back
/// when it finishes, which is how Jax knows what you actually heard.
final class AudioOut: NSObject, AVAudioPlayerDelegate {
    var onPlayed: ((Int, Int) -> Void)?

    private struct Piece {
        let utt: Int
        let idx: Int
        let data: Data
    }
    private var queue: [Piece] = []
    private var player: AVAudioPlayer?
    private var current: Piece?

    var isPlaying: Bool { player != nil }

    /// 0...1, how loud Jax is right now. Drives the orb.
    var level: Double {
        guard let player, player.isPlaying else { return 0 }
        player.updateMeters()
        let db = Double(player.averagePower(forChannel: 0)) // -160...0
        return max(0, min(1, (db + 50) / 50))
    }

    func enqueue(_ data: Data, utt: Int, idx: Int) {
        queue.append(Piece(utt: utt, idx: idx, data: data))
        if player == nil { playNext() }
    }

    func stop() {
        queue.removeAll()
        player?.delegate = nil
        player?.stop()
        player = nil
        current = nil
    }

    /// The server keeps exactly one piece alive: the one playing, or the next one if nothing started.
    func dropQueued() {
        if player != nil { queue.removeAll() } else if queue.count > 1 { queue.removeSubrange(1...) }
    }

    private func playNext() {
        while !queue.isEmpty {
            let piece = queue.removeFirst()
            do {
                let next = try AVAudioPlayer(data: piece.data)
                next.delegate = self
                next.isMeteringEnabled = true
                guard next.play() else { throw NSError(domain: "Jax", code: 2) }
                player = next
                current = piece
                return
            } catch {
                // A piece that will not play is still confirmed, so Jax's order keeps moving.
                log.error("audio piece would not play: \(error.localizedDescription, privacy: .public)")
                onPlayed?(piece.utt, piece.idx)
            }
        }
        player = nil
        current = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            if let done = self.current { self.onPlayed?(done.utt, done.idx) }
            self.player = nil
            self.current = nil
            self.playNext()
        }
    }
}
