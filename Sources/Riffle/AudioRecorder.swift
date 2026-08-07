import AVFoundation
import Accelerate
import CoreAudio

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
    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "riffle.audio.buffer")
    private var samples: [Float] = []
    private var nativeRate: Double = 48000
    private var autoStopFired = false
    private var graceTimer: Timer?
    private(set) var isRecording = false

    var maxSeconds = 240
    var graceSeconds: TimeInterval = 8
    // Human-readable name of the device the engine last captured from,
    // for the log and for "nothing heard" feedback (a warm engine can pin
    // an unexpected device after audio routes change).
    private(set) var lastCaptureDevice = "unknown input"
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
        observeEngine()
        observeDefaultInputDevice()
    }

    // The engine's configuration-change notification only fires when the
    // engine's own device goes away. When the system DEFAULT input moves to
    // a different device that still exists (headphones plugged in, display
    // reconnected), a warm engine keeps capturing the old device and hears
    // the wrong room. Watch the default-input property directly and drop
    // the idle engine so the next start rebinds.
    private func observeDefaultInputDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { [weak self] _, _ in
            guard let self else { return }
            Log.write("audio: system default input changed")
            if !isRecording {
                graceTimer?.invalidate()
                engine.stop()
                engine.reset()
            }
        }
    }

    // Name of the device the engine's input unit is bound to. The engine
    // usually binds the HAL's hidden default-device wrapper
    // ("CADefaultDeviceAggregate-<pid>-0"), which means nothing to a
    // human; resolve that to the actual current default input device.
    private func boundDeviceDescription() -> String {
        var deviceID = engine.inputNode.auAudioUnit.deviceID
        let raw = Self.deviceName(deviceID) ?? "unknown input"
        guard raw.hasPrefix("CADefaultDeviceAggregate") else { return raw }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown,
              let name = Self.deviceName(deviceID) else { return raw }
        return name
    }

    private static func deviceName(_ deviceID: AudioObjectID) -> String? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    // A kept-warm engine does not follow the system default input when
    // the device changes (headphones connecting, for example); it keeps
    // capturing a dead route, which records silence. The engine posts a
    // configuration-change notification for exactly this; tear it down
    // when idle so the next start rebinds to the current device.
    // Registered per engine instance, so a rebuild must call this again.
    private func observeEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
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

    // Replaces a wedged engine with a fresh instance. After some device
    // switches, reset() does not clear the input node's stale hardware
    // format and every start() fails with kAudioUnitErr_FormatNotSupported
    // (-10868) until the process restarts; only a new engine reliably
    // rebinds to the current device.
    private func rebuildEngine() {
        engine.stop()
        engine = AVAudioEngine()
        observeEngine()
        Log.write("audio: rebuilt engine after wedged start")
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
        if (try? startEngine()) == nil {
            rebuildEngine()
            try? startEngine()
        }
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
        do {
            try riffleCatching("engine start") {
                engine.prepare()
                try engine.start()
            }
        } catch {
            // A stale configuration (device switch) can wedge the engine;
            // reset once and retry. Failures beyond this get a full engine
            // rebuild from the caller.
            engine.stop()
            engine.reset()
            try riffleCatching("engine restart") {
                engine.prepare()
                try engine.start()
            }
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

        do {
            try beginCapture()
        } catch {
            // One full retry on a fresh engine: stale device state fails in
            // ways reset() cannot clear (wedged starts, tap installs raising
            // NSExceptions on a dead format). A rebuild rebinds everything
            // to the current device.
            Log.write("audio: capture failed (\(error.localizedDescription)), retrying on a fresh engine")
            rebuildEngine()
            do {
                try beginCapture()
            } catch {
                // The engine may still be running from the warm grace
                // window; without rescheduling the stop it would run (and
                // hold the mic) forever after a failed start.
                scheduleGraceStop(after: graceSeconds)
                throw error
            }
        }
        isRecording = true
    }

    // Engine up, format sane, record tap installed. The engine must be
    // running before the tap goes in: a failed start can rebuild the
    // engine, and a tap installed on the old instance would capture
    // nothing. The warm path already works this way (the engine runs
    // through the grace window, the tap joins later).
    private func beginCapture() throws {
        try startEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Riffle", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "no audio input device"])
        }
        nativeRate = format.sampleRate

        // format: nil makes the tap follow the node's live format. Passing
        // a queried format raises an uncatchable NSException whenever a
        // device switch has invalidated it (this crashed the app after a
        // meeting recording changed the input device). The authoritative
        // rate comes from the buffers themselves.
        let tap: (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let bufferRate = buffer.format.sampleRate
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            self.queue.async {
                if bufferRate > 0 { self.nativeRate = bufferRate }
                self.samples.append(contentsOf: chunk)
                let total = self.samples.count
                let maxSamples = self.maxSeconds > 0
                    ? Int(self.nativeRate * Double(self.maxSeconds))
                    : Int.max
                self.publishSpectrum()
                DispatchQueue.main.async {
                    if total >= maxSamples, self.isRecording, !self.autoStopFired {
                        self.autoStopFired = true
                        self.onAutoStop?()
                    }
                }
            }
        }
        try riffleCatching("record tap install") {
            input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tap)
        }
        lastCaptureDevice = boundDeviceDescription()
        Log.write("audio: capturing via \(lastCaptureDevice) at \(Int(format.sampleRate)) Hz")
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
