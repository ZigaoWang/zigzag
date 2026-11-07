import AVFoundation

/// Plays what extensions play from a tab capture, from Zigzag itself rather than through WebKit.
///
/// While an extension hears Zigzag's own sound (streamed video, SystemAudioTap), Zigzag's web audio is muted at the
/// source, as Chrome mutes a captured tab; what the extension then plays (Shazam passing the sound on, a booster's
/// louder copy) comes here, sample by sample, and plays on the Mac's output. Played here, outside WebKit, it never
/// comes back around into the capture. Each source (an extension page's audio context) has its own short queue, and
/// all of them are mixed.
nonisolated final class NativeAudioOut: @unchecked Sendable {
    static let shared = NativeAudioOut()

    private let rate: Double = 48_000
    private let lock = NSLock()
    /// Samples waiting to play, by source, at `rate`.
    private var queues: [String: [Float]] = [:]
    private var engine: AVAudioEngine?

    /// About a fiftieth of a second waits before a source starts, so uneven arrival doesn't crackle; never more than
    /// a tenth, so the sound stays with the picture.
    private var cushion: Int { Int(rate * 0.02) }
    private var most: Int { Int(rate * 0.1) }
    private var started = Set<String>()

    /// Adds a source's samples (mono, at their own rate).
    func feed(_ source: String, samples: [Float], rate sourceRate: Double) {
        guard !samples.isEmpty else { return }
        let resampled: [Float]
        if abs(sourceRate - rate) < 1 {
            resampled = samples
        } else {
            let ratio = sourceRate / rate
            let count = Int(Double(samples.count) / ratio)
            resampled = (0..<count).map { samples[min(samples.count - 1, Int(Double($0) * ratio))] }
        }
        lock.lock()
        var queue = queues[source, default: []]
        queue.append(contentsOf: resampled)
        if queue.count > most { queue.removeFirst(queue.count - most / 2) }
        queues[source] = queue
        lock.unlock()
        startIfNeeded()
    }

    /// A source is done (its capture ended): its sound stops; with none left, so does the player.
    func end(sourcesStartingWith prefix: String) {
        lock.lock()
        for key in queues.keys where key.hasPrefix(prefix) { queues[key] = nil; started.remove(key) }
        let empty = queues.isEmpty
        lock.unlock()
        if empty { stop() }
    }

    private func startIfNeeded() {
        lock.lock()
        let running = engine != nil
        lock.unlock()
        guard !running else { return }
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, buffers -> OSStatus in
            guard let self else { return noErr }
            let output = UnsafeMutableAudioBufferListPointer(buffers)
            guard let data = output.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let frames = Int(frameCount)
            for index in 0..<frames { data[index] = 0 }
            self.lock.lock()
            for key in self.queues.keys {
                guard var queue = self.queues[key] else { continue }
                if !self.started.contains(key) {
                    guard queue.count >= self.cushion else { continue }
                    self.started.insert(key)
                }
                let take = min(frames, queue.count)
                for index in 0..<take { data[index] += queue[index] }
                queue.removeFirst(take)
                // Ran dry: wait for a cushion again before going on.
                if take < frames { self.started.remove(key) }
                self.queues[key] = queue
            }
            self.lock.unlock()
            for index in 0..<frames { data[index] = max(-1, min(1, data[index])) }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        lock.lock()
        self.engine = engine
        lock.unlock()
    }

    private func stop() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        lock.unlock()
        engine?.stop()
    }
}
