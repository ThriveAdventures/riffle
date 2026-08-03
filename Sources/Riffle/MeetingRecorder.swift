import AVFoundation
import CoreAudio
import Foundation

// Records a meeting as two tracks: the microphone (you) and system audio
// (everyone else, via a Core Audio process tap, macOS 14.2+). Both stream
// to disk as raw float32 at native rate and are converted to 16 kHz WAVs
// on stop. Requires the System Audio Recording permission.
@available(macOS 14.2, *)
final class MeetingRecorder {

    struct Tracks {
        let micWav: URL
        let systemWav: URL
        let seconds: Double
    }

    private let micEngine = AVAudioEngine()
    private var micFile: FileHandle?
    private var micRate: Double = 48000
    private var micCount: Int = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var systemFile: FileHandle?
    private var systemRate: Double = 48000
    private var systemCount: Int = 0

    private let queue = DispatchQueue(label: "riffle.meeting.io")
    private var micPath = ""
    private var systemPath = ""
    private(set) var isRecording = false
    private(set) var startedAt = Date.distantPast

    func start() throws {
        guard !isRecording else { return }
        let tmp = FileManager.default.temporaryDirectory
        micPath = tmp.appendingPathComponent("riffle-meeting-mic-\(UUID().uuidString).f32").path
        systemPath = tmp.appendingPathComponent("riffle-meeting-sys-\(UUID().uuidString).f32").path
        FileManager.default.createFile(atPath: micPath, contents: nil)
        FileManager.default.createFile(atPath: systemPath, contents: nil)
        micFile = FileHandle(forWritingAtPath: micPath)
        systemFile = FileHandle(forWritingAtPath: systemPath)
        micCount = 0
        systemCount = 0

        try startSystemTap()
        do {
            try startMic()
        } catch {
            stopSystemTap()
            throw error
        }
        isRecording = true
        startedAt = Date()
        Log.write("meeting: recording started")
    }

    private func startMic() throws {
        let input = micEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Riffle", code: 50,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone available"])
        }
        micRate = format.sampleRate
        // format: nil follows the node's live format; a queried format can
        // be invalidated by device switches and installTap raises on it.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let bufferRate = buffer.format.sampleRate
            let data = Data(bytes: channel, count: count * 4)
            queue.async {
                if bufferRate > 0 { self.micRate = bufferRate }
                self.micFile?.write(data)
                self.micCount += count
            }
        }
        micEngine.prepare()
        try micEngine.start()
    }

    private func startSystemTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.name = "Riffle Meeting Tap"
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw NSError(domain: "Riffle", code: 51,
                          userInfo: [NSLocalizedDescriptionKey: "system audio tap failed (\(status)); grant System Audio Recording"])
        }
        tapID = newTapID

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Riffle Meeting Capture",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggID)
        guard status == noErr, newAggID != kAudioObjectUnknown else {
            stopSystemTap()
            throw NSError(domain: "Riffle", code: 52,
                          userInfo: [NSLocalizedDescriptionKey: "aggregate device failed (\(status))"])
        }
        aggregateID = newAggID

        systemRate = readSampleRate(of: aggregateID) ?? 48000

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for buffer in buffers {
                guard let base = buffer.mData else { continue }
                let channels = Int(buffer.mNumberChannels)
                let frames = Int(buffer.mDataByteSize) / 4 / max(channels, 1)
                guard frames > 0 else { continue }
                let floats = base.assumingMemoryBound(to: Float.self)
                if channels <= 1 {
                    self.systemFile?.write(Data(bytes: floats, count: frames * 4))
                } else {
                    var mono = [Float](repeating: 0, count: frames)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels { sum += floats[f * channels + c] }
                        mono[f] = sum / Float(channels)
                    }
                    mono.withUnsafeBufferPointer { p in
                        self.systemFile?.write(Data(buffer: p))
                    }
                }
                self.systemCount += frames
            }
        }
        guard status == noErr, let procID else {
            stopSystemTap()
            throw NSError(domain: "Riffle", code: 53,
                          userInfo: [NSLocalizedDescriptionKey: "io proc failed (\(status))"])
        }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stopSystemTap()
            throw NSError(domain: "Riffle", code: 54,
                          userInfo: [NSLocalizedDescriptionKey: "device start failed (\(status))"])
        }
    }

    private func readSampleRate(of objectID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    private func stopSystemTap() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    func stop() -> Tracks? {
        guard isRecording else { return nil }
        isRecording = false
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        stopSystemTap()
        queue.sync {
            try? micFile?.close()
            try? systemFile?.close()
            micFile = nil
            systemFile = nil
        }
        let seconds = Date().timeIntervalSince(startedAt)
        Log.write("meeting: stopped after \(Int(seconds))s, mic \(micCount) frames @\(Int(micRate)), system \(systemCount) frames @\(Int(systemRate))")

        do {
            let micWav = try Self.convertRawToWav(path: micPath, rate: micRate)
            let sysWav = try Self.convertRawToWav(path: systemPath, rate: systemRate)
            try? FileManager.default.removeItem(atPath: micPath)
            try? FileManager.default.removeItem(atPath: systemPath)
            return Tracks(micWav: micWav, systemWav: sysWav, seconds: seconds)
        } catch {
            Log.write("meeting: conversion failed: \(error.localizedDescription)")
            return nil
        }
    }

    // Stream-convert a raw float32 file to a 16 kHz mono WAV in chunks so
    // hour-long meetings never sit in memory.
    private static func convertRawToWav(path: String, rate: Double) throws -> URL {
        guard let inHandle = FileHandle(forReadingAtPath: path) else {
            throw NSError(domain: "Riffle", code: 55,
                          userInfo: [NSLocalizedDescriptionKey: "raw track missing"])
        }
        defer { try? inHandle.close() }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("riffle-meeting-\(UUID().uuidString).wav")
        var pcm = Data()
        let chunkFrames = Int(rate) * 60  // one minute per chunk
        while true {
            guard let data = try inHandle.read(upToCount: chunkFrames * 4), !data.isEmpty else { break }
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            pcm.append(try AudioRecorder.resamplePublic(samples: samples, sourceRate: rate))
        }
        let wav = AudioRecorder.wavDataPublic(pcm: pcm, sampleRate: 16000)
        try wav.write(to: outURL)
        return outURL
    }
}
