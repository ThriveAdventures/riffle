import AVFoundation
import Accelerate

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
    // 12 log-spaced voice-band magnitudes, 0...1, delivered on main.
    var spectrumHandler: (([Float]) -> Void)?
    var onAutoStop: (() -> Void)?

    private let fftSize = 2048
    private let fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
    private var hannWindow = [Float](repeating: 0, count: 2048)
    // Adaptive ceiling: bars scale relative to the session's own loudness,
    // so no fixed threshold can peg them regardless of mic or gain.
    private var dbCeiling: Float = -30

    init() {
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        // A kept-warm engine does not follow the system default input when
        // the device changes (headphones connecting, for example); it keeps
        // capturing a dead route, which records silence. The engine posts a
        // configuration-change notification for exactly this; tear it down
        // when idle so the next start rebinds to the current device.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.write("audio: engine configuration changed (input device switch)")
            if !isRecording {
                graceTimer?.invalidate()
                engine.stop()
                engine.reset()
            }
        }
    }

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
        // Touching inputNode attaches the input side of the graph. Starting
        // an engine with an empty graph raises an NSException (not a Swift
        // error), which either aborts the process or gets half-swallowed by
        // AppKit depending on the calling context.
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Riffle", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "no audio input device"])
        }
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

    // Leak watchdog, called periodically from the app's health timer. If
    // the engine is running while idle with no valid grace timer pending,
    // some path forgot the shutdown: coreaudiod then holds a display-sleep
    // assertion indefinitely (this kept a display awake for 89 hours).
    // Whatever the entry path, this makes the leak self-heal within a
    // minute.
    func watchdog() {
        guard !isRecording, engine.isRunning else { return }
        if graceTimer == nil || graceTimer?.isValid != true {
            Log.write("audio: watchdog stopped a leaked engine")
            engine.stop()
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
        dbCeiling = -30

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
            _ = rms
            self.queue.async {
                self.samples.append(contentsOf: chunk)
                let total = self.samples.count
                self.publishSpectrum()
                DispatchQueue.main.async {
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
            // The engine may still be running from the warm grace window;
            // without rescheduling the stop it would run (and hold the mic)
            // forever after a failed start.
            scheduleGraceStop(after: graceSeconds)
            throw error
        }
        isRecording = true
    }

    // Real spectrum for the HUD meter: Hann window, 2048-point FFT, 12
    // log-spaced bands over the voice range, dB-mapped to 0...1 with a
    // gentle treble tilt (speech rolls off up high).
    private func publishSpectrum() {
        guard isRecording, samples.count >= fftSize, let setup = fftSetup else { return }
        var frame = Array(samples.suffix(fftSize))
        vDSP_vmul(frame, 1, hannWindow, 1, &frame, 1, vDSP_Length(fftSize))
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { fb in
                    vDSP_ctoz(fb.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        let bandCount = 12
        var dbs = [Float](repeating: -80, count: bandCount)
        let fMin: Float = 100, fMax: Float = 6000
        let binHz = Float(nativeRate) / Float(fftSize)
        for b in 0..<bandCount {
            let lo = fMin * pow(fMax / fMin, Float(b) / Float(bandCount))
            let hi = fMin * pow(fMax / fMin, Float(b + 1) / Float(bandCount))
            let i0 = max(1, Int(lo / binHz))
            let i1 = min(half - 1, max(i0 + 1, Int(hi / binHz)))
            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            let mean = sum / Float(i1 - i0)
            dbs[b] = 10 * log10(max(mean, 1e-12))
        }
        // Ceiling rides the loudest band and releases slowly; each bar is
        // its distance below that ceiling within a 28 dB window. The meter
        // calibrates itself to the speaker within a second.
        let frameMax = dbs.max() ?? -80
        dbCeiling = max(frameMax, max(dbCeiling - 0.35, -45))
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let tilt = 0.92 + 0.3 * Float(b) / Float(bandCount - 1)
            let rel = (dbs[b] - (dbCeiling - 28)) / 28
            bands[b] = min(1, pow(max(0, rel), 1.15) * tilt)
        }
        DispatchQueue.main.async { self.spectrumHandler?(bands) }
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

    static func resamplePublic(samples: [Float], sourceRate: Double) throws -> Data {
        try resampleTo16kInt16(samples: samples, sourceRate: sourceRate)
    }

    static func wavDataPublic(pcm: Data, sampleRate: Int) -> Data {
        wavData(pcm: pcm, sampleRate: sampleRate)
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
