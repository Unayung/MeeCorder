// Turns a meeting's two tracks into transcript.md with whisper.cpp and Breeze ASR 25 (Taiwanese Mandarin
// mixed with English terms), on this Mac.
import AVFoundation
import Foundation
import whisper

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Meet Recorder")
let modelURL = supportDir.appendingPathComponent("ggml-breeze-asr-25-q5_k.bin")
let modelSource = URL(string: "https://huggingface.co/shdennlin/breeze-asr-25-ggml/resolve/main/ggml-breeze-asr-25-q5_k.bin")!

struct Line {
    let start: Double, end: Double, speaker: String, text: String
}

/// Through speakers the other side leaks into the microphone. A mic line is that echo when it overlaps a
/// system line in time and most of its characters are in that line; talking over someone says other words.
func isEcho(_ mic: Line, _ system: [Line]) -> Bool {
    let chars = mic.text.filter { $0.isLetter || $0.isNumber }
    guard !chars.isEmpty else { return true }
    return system.contains { other in
        guard mic.start < other.end + 1, mic.end > other.start - 1 else { return false }
        return Double(chars.filter(other.text.contains).count) / Double(chars.count) >= 0.5
    }
}

// MARK: Model

final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        if expected > 0 { report(Double(written) / Double(expected)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// Downloads the speech model (about 1.1 GB) the first time. It only takes its final name once complete.
func ensureModel(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
    if FileManager.default.fileExists(atPath: modelURL.path) { return modelURL }
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let (file, response) = try await URLSession.shared.download(from: modelSource, delegate: DownloadProgress(progress))
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        try? FileManager.default.removeItem(at: file)
        throw CoreAudioError(what: "Downloading the speech model", status: -1)
    }
    try FileManager.default.moveItem(at: file, to: modelURL)
    return modelURL
}

// MARK: Transcription

/// One track as 16 kHz mono samples: its segments back to back, so the timeline matches the other track.
func samples(_ files: [URL]) throws -> [Float] {
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    var all: [Float] = []
    for url in files {
        // A segment that can't be read (cut short by a crash) is skipped rather than failing the meeting.
        guard let file = try? AVAudioFile(forReading: url),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            log("skipping unreadable \(url.lastPathComponent)")
            continue
        }
        while file.framePosition < file.length {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000 * 10) else { break }
            try file.read(into: chunk)
            let ratio = target.sampleRate / file.processingFormat.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: target,
                                             frameCapacity: AVAudioFrameCount(Double(chunk.frameLength) * ratio) + 64) else { break }
            var fed = false, error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return chunk
            }
            if let error { throw error }
            all += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
        }
    }
    return all
}

/// Same settings as life-recorder's receiver: whisper-cli's defaults (beam search of 5), Chinese, and the
/// Silero voice activity model, which skips silence, where Whisper hallucinates most.
func transcribe(_ context: OpaquePointer, _ audio: [Float], speaker: String) -> [Line] {
    guard !audio.isEmpty else { return [] }
    let vadModel = Bundle.main.url(forResource: "ggml-silero-v6.2.0", withExtension: "bin")?.path
    var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
    params.beam_search.beam_size = 5
    params.greedy.best_of = 5
    params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
    params.print_progress = false
    params.print_realtime = false
    params.print_timestamps = false
    let status: Int32 = "zh".withCString { language in
        params.language = language
        return (vadModel ?? "").withCString { vad in
            if vadModel != nil {
                params.vad = true
                params.vad_model_path = vad
            }
            return audio.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
        }
    }
    guard status == 0 else {
        log("whisper failed on the \(speaker) track (\(status))")
        return []
    }
    return (0..<whisper_full_n_segments(context)).compactMap { i in
        let text = cleanSegment(String(cString: whisper_full_get_segment_text(context, i)))
        guard !text.isEmpty else { return nil }
        // Segment times are in hundredths of a second.
        return Line(start: Double(whisper_full_get_segment_t0(context, i)) / 100,
                    end: Double(whisper_full_get_segment_t1(context, i)) / 100, speaker: speaker, text: text)
    }
}

/// Drops what Whisper makes up rather than hears, after life-recorder's clean_transcript.
func cleanSegment(_ raw: String) -> String {
    var text = raw.precomposedStringWithCompatibilityMapping
    for pattern in [
        #"\[[^\]]{0,120}\]"#,                                              // [silence], [BLANK_AUDIO]
        #"[(（]\s*(?:音樂|掌聲|笑聲|music|applause|laughter|noise|inaudible)[^)）]*[)）]"#,
        #"<\|[^|<>]{0,16}\|>"#,                                             // leaked timestamp tokens
        #"\S*Amara\.org\S*|[請请]不吝[點点][贊讚赞][^。!?\n]{0,40}|明[鏡镜][與与][點点]{2}[欄栏]目"#,
    ] {
        text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
    }
    text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    // Video sign-offs Whisper learned from subtitles, when they are the whole segment.
    let signOff = #"^(?:[謝谢]{2}|感[謝谢])(?:大家|各位)?(?:的)?(?:[觀观]看|收看|收[聽听])[\s.!。]*$|^(?:[請请])?[訂订][閱阅](?:我的)?[頻频][道][\s.!。]*$"#
    if text.range(of: signOff, options: .regularExpression) != nil || !text.contains(where: { $0.isLetter || $0.isNumber }) {
        return ""
    }
    // Collapse a decoder loop of a longer phrase; short repeats ("要換要換") are natural emphasis.
    return text.replacingOccurrences(of: #"(\S{4,20}?)\1{2,}"#, with: "$1", options: .regularExpression)
}

func timestamp(_ seconds: Double) -> String {
    let s = Int(seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}

/// Writes `transcript.md` into the meeting folder and returns its URL.
@discardableResult
func makeTranscript(meeting: URL, model: URL) async throws -> URL {
    let audio = meeting.appendingPathComponent("audio")
    var cparams = whisper_context_default_params()
    cparams.use_gpu = true
    guard let context = whisper_init_from_file_with_params(model.path, cparams) else {
        throw CoreAudioError(what: "Loading the speech model", status: -1)
    }
    defer { whisper_free(context) }
    let system = transcribe(context, try samples(segments(in: audio, track: "system")), speaker: "對方")
    let mic = transcribe(context, try samples(segments(in: audio, track: "mic")), speaker: "我").filter { !isEcho($0, system) }
    var text = "# \(meeting.lastPathComponent)\n\n"
    for line in (mic + system).sorted(by: { $0.start < $1.start }) {
        text += "[\(timestamp(line.start))] \(line.speaker)：\(line.text)\n\n"
    }
    let url = meeting.appendingPathComponent("transcript.md")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}
