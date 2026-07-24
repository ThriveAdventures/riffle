import AVFoundation

// Captures microphone audio at the device's native rate, then resamples to
// 16 kHz mono 16-bit WAV, which is what whisper.cpp expects.
final class AudioRecorder {

    struct Recording {
        let url: URL
        let seconds: Double
        let peak: Float
    }

    // One engine for the app's lifetime, kept running for a grace window
    // after each dictation and pre-warmed at launch. Cold microphone
    // spin-up costs 100-300 ms and clips the first syllable when the user
    // speaks the instant they press the hotkey; a warm engine does not.
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "riffle.audio.buffer")
    private var samples: [Float] = []
    private var nativeRate: Double = 48000
    private var autoStopFired = false
    private var graceTimer: Timer?
    private(set) var isRecording = false

    var maxSeconds = 240
    var graceSeconds: TimeInterval = 8
    var levelHandler: ((Float) -> Void)?
    var onAutoStop: (() -> Void)?

    static func requestMicAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    // Spins the engine up (or reuses the already-running one) so the mic
    // route is live before the user's first word.
    func warmup() {
        guard !isRecording else { return }
        try? startEngine()
        scheduleGraceStop(after: 1.5)
    }

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // A stale configuration (device switch) can wedge the engine;
            // reset once and retry.
            engine.stop()
            engine.reset()
            engine.prepare()
            try engine.start()
        }
    }

    private func scheduleGraceStop(after interval: TimeInterval) {
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, !isRecording else { return }
            engine.stop()
        }
    }

    func start() throws {
        guard !isRecording else { return }
        graceTimer?.invalidate()
        queue.sync { samples.removeAll(keepingCapacity: true) }
        autoStopFired = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Riffle", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "no audio input device"])
        }
        nativeRate = format.sampleRate
        let maxSamples = maxSeconds > 0 ? Int(format.sampleRate * Double(maxSeconds)) : Int.max

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            var sum: Float = 0
            for v in chunk { sum += v * v }
            let rms = sqrt(sum / Float(count))
            self.queue.async {
                self.samples.append(contentsOf: chunk)
                let total = self.samples.count
                DispatchQueue.main.async {
                    self.levelHandler?(min(1, rms * 16))
                    if total >= maxSamples, self.isRecording, !self.autoStopFired {
                        self.autoStopFired = true
                        self.onAutoStop?()
                    }
                }
            }
        }

        do {
            try startEngine()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        scheduleGraceStop(after: graceSeconds)
        queue.sync { samples.removeAll() }
    }

    func stop() -> Recording? {
        guard isRecording else { return nil }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        scheduleGraceStop(after: graceSeconds)

        var captured: [Float] = []
        queue.sync {
            captured = samples
            samples.removeAll()
        }

        let seconds = Double(captured.count) / nativeRate
        guard seconds >= 0.35 else { return nil }
        var peak: Float = 0
        for v in captured { peak = max(peak, abs(v)) }

        do {
            let pcm = try Self.resampleTo16kInt16(samples: captured, sourceRate: nativeRate)
            let wav = Self.wavData(pcm: pcm, sampleRate: 16000)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("riffle-\(UUID().uuidString).wav")
            try wav.write(to: url)
            return Recording(url: url, seconds: seconds, peak: peak)
        } catch {
            Log.write("audio: wav conversion failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func resampleTo16kInt16(samples: [Float], sourceRate: Double) throws -> Data {
        func fail(_ message: String) -> NSError {
            NSError(domain: "Riffle", code: 11, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                         channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                          channels: 1, interleaved: true),
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw fail("could not create audio converter") }

        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                inBuffer.floatChannelData?[0].update(from: base, count: samples.count)
            }
        }

        var pcm = Data()
        var fed = false
        var done = false
        while !done {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16384)
            else { throw fail("could not allocate output buffer") }
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let convError { throw convError }
            let frames = Int(outBuffer.frameLength)
            if frames > 0, let channel = outBuffer.int16ChannelData?[0] {
                channel.withMemoryRebound(to: UInt8.self, capacity: frames * 2) { bytes in
                    pcm.append(bytes, count: frames * 2)
                }
            }
            switch status {
            case .haveData:
                continue
            case .endOfStream, .inputRanDry:
                done = true
            case .error:
                throw fail("audio conversion error")
            @unknown default:
                done = true
            }
        }
        return pcm
    }

    private static func wavData(pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + pcm.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16)
        u16(1)                              // PCM
        u16(1)                              // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))         // byte rate
        u16(2)                              // block align
        u16(16)                             // bits per sample
        d.append("data".data(using: .ascii)!)
        u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
