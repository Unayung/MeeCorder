// Records a meeting on a Mac as two tracks: the microphone (you) and everything the Mac plays (the others).
//
// System audio comes from a Core Audio process tap, so no virtual audio driver is needed. Each track is
// written in 60-second AAC files, so a crash loses at most the last minute.
import AVFoundation
import CoreAudio
import Foundation

let meetingApps = ["com.microsoft.edgemac", "com.google.Chrome", "com.tinyspeck.slackmacgap", "us.zoom.xos",
                   "com.microsoft.teams2"]
let segmentSeconds = 60.0
let outputRate = 16_000.0

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    fflush(stdout)
}

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String, status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

// MARK: Core Audio properties

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var addr = address(selector, scope), value = initial, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func readObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = address(selector, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector), value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func processObject(for pid: pid_t) -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject), pid = pid
    var object = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    return status == noErr && object != kAudioObjectUnknown ? object : nil
}

func defaultInputDevice() -> AudioObjectID? {
    read(systemObject, kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown))
        .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
}

/// Processes other than this one that are currently taking microphone input.
func micClients() -> [(pid: pid_t, bundle: String)] {
    readObjects(systemObject, kAudioHardwarePropertyProcessObjectList).compactMap { object in
        guard read(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
              let pid = read(object, kAudioProcessPropertyPID, pid_t(0)), pid != getpid() else { return nil }
        return (pid, readString(object, kAudioProcessPropertyBundleID) ?? "")
    }
}

/// Bundle IDs match by prefix, so a browser's helper processes (which own the mic in Chromium) count too.
func meetingApp(_ apps: [String] = meetingApps) -> String? {
    micClients().first { client in apps.contains { client.bundle.hasPrefix($0) } }?.bundle
}

// MARK: Recording

/// Writes one track as mono 16 kHz AAC in 60-second files, `<track>-0001.m4a` and on. A file gets its
/// name only once it is closed, so a file left half-written by a crash keeps its `.partial-` prefix.
final class SegmentWriter {
    private let dir: URL, track: String
    private let input: AVAudioFormat, output: AVAudioFormat, converter: AVAudioConverter
    private var file: AVAudioFile?, index: Int, frames: AVAudioFramePosition = 0, lastError = ""

    init(dir: URL, track: String, firstIndex: Int, inputRate: Double) throws {
        self.dir = dir
        self.track = track
        index = firstIndex
        input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw CoreAudioError(what: "Sample rate converter", status: -1)
        }
        self.converter = converter
    }

    private var name: String { String(format: "%@-%04d.m4a", track, index) }
    private var partial: URL { dir.appendingPathComponent(".partial-" + name) }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity:
                AVAudioFrameCount(Double(samples.count) * outputRate / input.sampleRate) + 64) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var fed = false, error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard converted.frameLength > 0 else { return }
        do {
            if file == nil {
                frames = 0
                file = try AVAudioFile(forWriting: partial, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: outputRate, AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000,  // Plenty for speech; 64k is above what AAC allows at 16 kHz mono.
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            try file!.write(from: converted)
            frames += AVAudioFramePosition(converted.frameLength)
            if Double(frames) >= segmentSeconds * outputRate { close() }
        } catch {
            if "\(error)" != lastError { log("writing \(name) failed: \(error)") }
            lastError = "\(error)"
            file = nil
            try? FileManager.default.removeItem(at: partial)
        }
    }

    func close() {
        guard let file else { return }
        file.close()
        self.file = nil
        try? FileManager.default.moveItem(at: partial, to: dir.appendingPathComponent(name))
        index += 1
    }
}

/// The finished segments of one track, in order.
func segments(in dir: URL, track: String) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(track + "-") && $0.pathExtension == "m4a" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// A private aggregate device of the current microphone plus a tap on every other process's output. The two
/// arrive as separate streams, so each is written to its own track.
final class MeetingCapture {
    let mic: AudioObjectID
    private var tap = AudioObjectID(kAudioObjectUnknown), aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "capture.io")
    private var writers: [SegmentWriter] = []

    init(dir: URL) throws {
        guard let mic = defaultInputDevice(), let micUID = readString(mic, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(what: "Finding the microphone", status: -1)
        }
        self.mic = mic
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processObject(for: getpid()).map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Meet Recorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the system audio tap")
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meet Recorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Creating the aggregate device")
            // Each input stream arrives as one interleaved buffer or one buffer per channel. The microphone's
            // streams come first, then the tap's.
            var layout: [Int] = []
            for stream in readObjects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) {
                guard let format = read(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()),
                      format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      format.mBitsPerChannel == 32 else {
                    throw CoreAudioError(what: "Reading a 32-bit float input stream", status: -1)
                }
                layout.append(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(format.mChannelsPerFrame) : 1)
            }
            let micStreams = readObjects(mic, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
            guard micStreams > 0, micStreams < layout.count else {
                throw CoreAudioError(what: "Telling the microphone from the system audio", status: -1)
            }
            let micBuffers = layout.prefix(micStreams).reduce(0, +)
            let rate = read(aggregate, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
            guard rate > 0 else { throw CoreAudioError(what: "Reading the sample rate", status: -1) }
            // After a restart (a new microphone) the tracks carry on from the next segment number.
            let next = (segments(in: dir, track: "mic").count) + 1
            let writers = try ["mic", "system"].map {
                try SegmentWriter(dir: dir, track: $0, firstIndex: next, inputRate: rate)
            }
            self.writers = writers
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, first.mNumberChannels > 0 else { return }
                let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
                // If the buffers don't match the stream layout, assume one buffer per stream.
                let split = layout.reduce(0, +) == buffers.count ? micBuffers : micStreams
                writers[0].append(MeetingCapture.downmix(buffers, 0..<split, frames: frames))
                writers[1].append(MeetingCapture.downmix(buffers, split..<buffers.count, frames: frames))
            }, "Creating the capture callback")
            try check(AudioDeviceStart(aggregate, proc), "Starting capture")
        } catch {
            teardown()
            throw error
        }
    }

    /// Averages every channel of the buffers in `range` into one.
    static func downmix(_ buffers: UnsafeMutableAudioBufferListPointer, _ range: Range<Int>, frames: Int) -> [Float] {
        var mixed = [Float](repeating: 0, count: frames)
        let channels = buffers[range].reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return mixed }
        let scale = 1 / Float(channels)
        for buffer in buffers[range] {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let width = Int(buffer.mNumberChannels)
            for frame in 0..<min(frames, Int(buffer.mDataByteSize) / (4 * width)) {
                for channel in 0..<width { mixed[frame] += data[frame * width + channel] * scale }
            }
        }
        for i in mixed.indices { mixed[i] = max(-1, min(1, mixed[i])) }
        return mixed
    }

    func stop() {
        teardown()
        queue.sync { writers.forEach { $0.close() } }
    }

    private func teardown() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
            self.proc = nil
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}
