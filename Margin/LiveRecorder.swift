import AVFoundation

enum SpeechLanguage {
    static let key = "speechLanguage"
    static let all: [(code: String, name: String)] = [
        ("en", "English"), ("auto", "Detect Automatically"), ("hi", "Hindi"), ("bn", "Bengali"), ("ta", "Tamil"), ("te", "Telugu"), ("mr", "Marathi"), ("ur", "Urdu"),
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("pt", "Portuguese"), ("ru", "Russian"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("ar", "Arabic"),
    ]
}

/// Runs Whisper one request at a time on its own thread.
final class LocalWhisper: @unchecked Sendable {
    static let shared = LocalWhisper()
    static let sampleRate = 16_000.0

    private let queue = DispatchQueue(label: "margin.whisper", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var openModel: String?

    private final class Collector {
        var lines: [TranscriptLine] = []
        let offset: TimeInterval
        init(offset: TimeInterval) { self.offset = offset }
    }

#if canImport(UIKit)
    @MainActor static var isAvailable: Bool { margin_whisper_supported() && (ModelDownloads.shared.isInstalled(.speech) || ModelFile.speech.isInstalled || ModelFile.speechWorld.isInstalled) }
#else
    static var isAvailable: Bool { margin_whisper_supported() && (ModelFile.speech.isInstalled || ModelFile.speechWorld.isInstalled) }
#endif

    func transcribe(_ samples: [Float], offset: TimeInterval) async throws -> [TranscriptLine] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try run(samples, offset: offset) })
            }
        }
    }

    private func run(_ samples: [Float], offset: TimeInterval) throws -> [TranscriptLine] {
        // Read for each chunk, so changing it during a recording takes effect straight away.
        let wanted = UserDefaults.standard.string(forKey: SpeechLanguage.key) ?? "en"
        let preferred = wanted == "en" ? ModelFile.speech : ModelFile.speechWorld
        let model = preferred.isInstalled ? preferred : (wanted == "en" ? ModelFile.speechWorld : ModelFile.speech)
        let language = model.name == ModelFile.speech.name ? "en" : wanted
        if openModel != model.name {
            margin_whisper_close(handle)
            handle = margin_whisper_open(model.path.path)
            openModel = handle == nil ? nil : model.name
        }
        guard let handle else { throw AIError.failed }
        let collector = Collector(offset: offset)
        let threads = Int32(max(ProcessInfo.processInfo.activeProcessorCount - 2, 2))
        let status = samples.withUnsafeBufferPointer { buffer in
            margin_whisper_transcribe(handle, buffer.baseAddress, Int32(buffer.count), threads, language, { start, _, text, user in
                let collector = Unmanaged<Collector>.fromOpaque(user!).takeUnretainedValue()
                let line = String(cString: text!).trimmingCharacters(in: .whitespacesAndNewlines)
                if TextTools.isSpeech(line) { collector.lines.append(TranscriptLine(time: start + collector.offset, text: line)) }
            }, Unmanaged.passUnretained(collector).toOpaque())
        }
        guard status == Int32(margin_ok) else { throw AIError.failed }
        return collector.lines
    }
}

enum Transcriber {
    /// Decodes an audio file a few minutes at a time, so an hour-long lecture doesn't sit in memory at once.
    static func transcribe(file url: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [TranscriptLine] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LocalWhisper.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw AIError.failed }
        let chunkFrames = AVAudioFrameCount(LocalWhisper.sampleRate * 300)
        let total = max(Double(file.length) / file.processingFormat.sampleRate, 0.001)
        var lines: [TranscriptLine] = [], offset: TimeInterval = 0, finished = false

        while !finished {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunkFrames) else { throw AIError.failed }
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { count, inputStatus in
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                      (try? file.read(into: input, frameCount: count)) != nil, input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw failure ?? AIError.failed }
            if status == .endOfStream || output.frameLength < chunkFrames { finished = true }
            guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { continue }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            lines += try await LocalWhisper.shared.transcribe(samples, offset: offset)
            offset += Double(output.frameLength) / LocalWhisper.sampleRate
            let done = min(offset / total, 1)
            await progress(done)
        }
        return lines
    }
}

/// Records the mic to a file while transcribing the same audio on the device, a few seconds at a time.
/// Not main-actor: the audio tap runs on its own thread.
final class LiveRecorder: @unchecked Sendable {
    /// Called on the main thread with the transcript so far.
    var onTranscript: (([TranscriptLine]) -> Void)?
    /// Called on the main thread once the last of the audio has been transcribed.
    var onFinished: (([TranscriptLine]) -> Void)?

    private static let chunkSeconds = 8.0

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LocalWhisper.sampleRate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var pending: [Float] = []
    private var consumed = 0
    private var transcribing = false
    private var stopped = false
    private var lines: [TranscriptLine] = []
    private var startedAt = Date()

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    func start(url: URL, transcribe: Bool) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.fileWriteUnknown) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        file = output
        if transcribe { converter = AVAudioConverter(from: format, to: speechFormat) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? output.write(from: buffer)
            self?.collect(buffer)
        }
        engine.prepare()
        try engine.start()
        startedAt = Date()
    }

    private func collect(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * LocalWhisper.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: capacity) else { return }
        var supplied = false
        converter.convert(to: output, error: nil) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        lock.lock()
        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        lock.unlock()
        transcribeIfReady()
    }

    private func transcribeIfReady() {
        lock.lock()
        let wanted = Int(Self.chunkSeconds * LocalWhisper.sampleRate)
        guard !transcribing, stopped ? !pending.isEmpty : pending.count >= wanted else {
            let idle = !transcribing && stopped
            lock.unlock()
            if idle { finish() }
            return
        }
        // Cut in a pause where possible, so a word isn't split between two chunks.
        let cut = stopped ? pending.count : TextTools.quietCut(pending, searchingLast: Int(LocalWhisper.sampleRate))
        let chunk = Array(pending[..<cut])
        pending.removeFirst(cut)
        let offset = Double(consumed) / LocalWhisper.sampleRate
        consumed += cut
        transcribing = true
        lock.unlock()

        Task {
            let new = (try? await LocalWhisper.shared.transcribe(chunk, offset: offset)) ?? []
            lock.withLock {
                lines += new
                transcribing = false
            }
            let snapshot = lock.withLock { lines }
            DispatchQueue.main.async { self.onTranscript?(snapshot) }
            transcribeIfReady()
        }
    }

    private func finish() {
        let snapshot = lock.withLock { lines }
        DispatchQueue.main.async {
            self.onFinished?(snapshot)
            self.onFinished = nil
        }
    }

    /// Stops and finalises the file. Returns the duration; the rest of the transcript arrives through `onFinished`.
    func stop() -> TimeInterval {
        let duration = elapsed
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // AVAudioFile closes the m4a when released
        lock.withLock { stopped = true }
        transcribeIfReady()
        return duration
    }
}
