// A menu bar app: records a meeting while a call app holds the microphone, then writes a transcript.
import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

let graceSeconds: TimeInterval = 30  // A muted mic or a rejoin shouldn't split one meeting into two recordings.
let meetingsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Meetings")

/// Goes in front of the transcript when it is copied for an AI tool.
let summaryPrompt = """
以下是一場會議的語音辨識逐字稿。「我」是錄音者本人，「對方」是會議中的其他人（可能不只一位）。
辨識可能把人名、產品名或英文術語聽錯，請依上下文判斷；無法確定的請標「（待確認）」。

請整理：
1. 三句話以內的會議重點
2. 做出的決定
3. 待辦事項：誰、做什麼、期限（逐字稿沒提到就寫「未提及」）
4. 還沒有結論、需要追蹤的問題
"""

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { args.index(after: $0) < args.endIndex ? args[$0 + 1] : nil }
        }
        // For checking without the menu: record a few seconds, or transcribe a meeting folder, then quit.
        if let seconds = option("--test-record").flatMap(Double.init) {
            let meeting = URL(fileURLWithPath: option("--out") ?? FileManager.default.currentDirectoryPath)
            do {
                let capture = try MeetingCapture(dir: meeting.appendingPathComponent("audio"))
                log("test recording \(Int(seconds))s into \(meeting.path)")
                Thread.sleep(forTimeInterval: seconds)
                capture.stop()
                log("test recording done")
                exit(0)
            } catch {
                log("test recording failed: \(error)")
                exit(1)
            }
        }
        if args.contains("--self-test") {
            let other = [Line(start: 3, end: 9, speaker: "對方", text: "好的，我這邊 PR 已經送出去了")]
            precondition(isEcho(Line(start: 3, end: 5, speaker: "我", text: "好的 ，我這邊批。"), other))
            precondition(!isEcho(Line(start: 4, end: 6, speaker: "我", text: "明天下午三點再確認"), other))
            precondition(!isEcho(Line(start: 20, end: 22, speaker: "我", text: "好的我這邊"), other))
            precondition(cleanSegment(" ( 音樂 )").isEmpty)
            precondition(cleanSegment("[BLANK_AUDIO]").isEmpty)
            precondition(cleanSegment("謝謝觀看").isEmpty)
            precondition(cleanSegment(" 好啦就這樣囉 bye bye") == "好啦就這樣囉 bye bye")
            precondition(cleanSegment("我們下週再討論我們下週再討論我們下週再討論") == "我們下週再討論")
            precondition(speechStart(81, 157, speech: [(81, 82.5), (151, 170)]) == 151)
            precondition(speechStart(10, 15, speech: [(9, 12), (12.5, 16)]) == 10)
            log("self-test passed")
            exit(0)
        }
        if let folder = option("--transcribe") {
            Task {
                do {
                    let started = Date()
                    let url = try await makeTranscript(meeting: URL(fileURLWithPath: folder), model: ensureModel())
                    log(String(format: "wrote %@ in %.1fs", url.path, Date().timeIntervalSince(started)))
                    exit(0)
                } catch {
                    log("transcription failed: \(error)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        MeeCorderApp.main()
    }
}

struct MeeCorderApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(recorder)
        } label: {
            Image(systemName: recorder.recording != nil ? "record.circle.fill"
                  : recorder.transcribing > 0 ? "text.bubble" : "mic")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class Recorder: ObservableObject {
    struct Recording { let meeting: URL, since: Date, capture: MeetingCapture }

    @Published var recording: Recording?
    @Published var transcribing = 0
    @Published var recent: [URL] = []
    @Published var autoRecord = UserDefaults.standard.object(forKey: "autoRecord") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "autoRecord") }
    }
    @Published var error: String?
    @Published var downloadProgress: Double?
    private var download: Task<URL, Error>?
    private var queue: Task<Void, Never>?
    private var lastSeen = Date.distantPast
    private var catchingUp = false
    private var skipThisMeeting = false  // Stopped by hand while the call goes on: don't start again until it ends.
    private var timer: Timer?

    init() {
        try? FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: vocabularyURL.path) {
            try? """
            # 會議裡常出現的人名、產品名、英文術語，一行一個，辨識時會參考這些寫法。
            # 開頭是 # 的行是說明，不會用到。例如：
            # Johnson
            # staging
            """.write(to: vocabularyURL, atomically: true, encoding: .utf8)
        }
        // Ask now rather than in the first seconds of a meeting, which would be lost until the prompt is answered.
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.askForSystemAudio() } }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        // Fetch the speech model right after install, not when the first meeting ends.
        Task { try? await model() }
        // A meeting cut off by a crash or a restart still gets its transcript.
        for meeting in recent where !FileManager.default.fileExists(atPath: meeting.appendingPathComponent("transcript.md").path) {
            finish(meeting)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        if let current = recording { catchUp(current.meeting) }
        if meetingApp() != nil {
            lastSeen = Date()
            if let current = recording {
                if defaultInputDevice() != current.capture.mic {
                    // Carry on in the same meeting folder with the new microphone.
                    current.capture.stop()
                    recording = nil
                    start(current.meeting, since: current.since)
                }
            } else if autoRecord && !skipThisMeeting {
                start()
                notify("開始錄音", "記得告訴與會者正在錄音。按選單列的圖示可以停止。")
            }
        } else if Date().timeIntervalSince(lastSeen) > graceSeconds {
            skipThisMeeting = false
            if recording != nil { stop() }
        }
    }

    func start(_ existing: URL? = nil, since: Date = Date()) {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HHmm"
        let meeting = existing ?? meetingsDir.appendingPathComponent("\(format.string(from: since)) 會議")
        do {
            let capture = try MeetingCapture(dir: meeting.appendingPathComponent("audio"))
            recording = Recording(meeting: meeting, since: since, capture: capture)
            error = nil
            refresh()
        } catch {
            self.error = "無法開始錄音：\(error)"
            log("could not start recording: \(error)")
        }
    }

    func stop(byHand: Bool = false) {
        guard let current = recording else { return }
        if byHand && meetingApp() != nil { skipThisMeeting = true }
        current.capture.stop()
        recording = nil
        finish(current.meeting)
    }

    /// Meetings are transcribed one after another: each holds the 1.1 GB model in memory.
    private func finish(_ meeting: URL) {
        transcribing += 1
        let previous = queue
        queue = Task {
            await previous?.value
            do {
                try await makeTranscript(meeting: meeting, model: model())
                notify("逐字稿完成", meeting.lastPathComponent)
            } catch {
                self.error = "轉寫失敗：\(error)"
                log("transcription of \(meeting.lastPathComponent) failed: \(error)")
            }
            transcribing -= 1
            refresh()
        }
    }

    /// Transcribes each minute once it is recorded, so the transcript is ready moments after the meeting.
    /// Waits for the model rather than starting its download; finish() does that.
    private func catchUp(_ meeting: URL) {
        guard !catchingUp, FileManager.default.fileExists(atPath: modelURL.path) else { return }
        catchingUp = true
        let previous = queue
        queue = Task {
            await previous?.value
            do {
                _ = try await meetingLines(meeting: meeting, model: modelURL)
            } catch {
                log("transcribing \(meeting.lastPathComponent) as it records failed: \(error)")
            }
            catchingUp = false
        }
    }

    /// The speech model, downloaded once. A failed download is tried again on the next call.
    func model() async throws -> URL {
        if let download { return try await download.value }
        let task = Task {
            try await ensureModel { fraction in
                Task { @MainActor in self.downloadProgress = fraction }
            }
        }
        download = task
        if !FileManager.default.fileExists(atPath: modelURL.path) { downloadProgress = 0 }
        defer { downloadProgress = nil }
        do {
            return try await task.value
        } catch {
            download = nil
            self.error = "語音模型下載失敗：\(error.localizedDescription)"
            throw error
        }
    }

    /// macOS has no call that asks for system audio access; it asks when audio is first captured. So capture two
    /// seconds once, after the microphone question, and throw them away.
    private func askForSystemAudio() {
        guard !UserDefaults.standard.bool(forKey: "askedForSystemAudio"), recording == nil else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard let capture = try? MeetingCapture(dir: dir) else { return }
        UserDefaults.standard.set(true, forKey: "askedForSystemAudio")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            capture.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func refresh() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: meetingsDir, includingPropertiesForKeys: nil,
                                                                    options: .skipsHiddenFiles)) ?? []
        recent = Array(folders.filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(5))
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

struct MenuView: View {
    @EnvironmentObject var recorder: Recorder
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var copied: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = recorder.recording {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label("錄音中 \(timestamp(context.date.timeIntervalSince(current.since)))", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                }
                Button("停止錄音") { recorder.stop(byHand: true) }
            } else {
                Text(recorder.transcribing > 0 ? "正在產生逐字稿…" : "待命中")
                Button("開始錄音") { recorder.start() }
            }
            if let fraction = recorder.downloadProgress {
                ProgressView("下載語音模型（只有第一次，約 1.1 GB）", value: fraction)
                    .font(.caption)
            }
            if let error = recorder.error {
                Text(error).font(.caption).foregroundStyle(.red)
                if !FileManager.default.fileExists(atPath: modelURL.path) && recorder.downloadProgress == nil {
                    Button("重新下載語音模型") { Task { try? await recorder.model() } }
                }
            }
            Divider()
            Toggle("偵測到會議時自動錄音", isOn: $recorder.autoRecord)
            Toggle("登入時啟動", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            Divider()
            Text("最近的會議").font(.caption).foregroundStyle(.secondary)
            ForEach(recorder.recent, id: \.self) { meeting in
                let transcript = meeting.appendingPathComponent("transcript.md")
                let done = FileManager.default.fileExists(atPath: transcript.path)
                HStack {
                    Button(meeting.lastPathComponent) {
                        NSWorkspace.shared.open(done ? transcript : meeting)
                    }
                    .buttonStyle(.link)
                    Spacer()
                    if done {
                        Button(copied == meeting ? "已複製" : "複製給 AI") {
                            let text = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summaryPrompt + "\n\n" + text, forType: .string)
                            copied = meeting
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == meeting { copied = nil } }
                        }
                        .help("把整理會議的指示和逐字稿一起複製，貼到 ChatGPT、Claude 等 AI 工具")
                    }
                }
            }
            Divider()
            HStack {
                Button("打開會議資料夾") { NSWorkspace.shared.open(meetingsDir) }
                Button("編輯詞彙") { NSWorkspace.shared.open(vocabularyURL) }
                    .help("加入會議常出現的人名、產品名、術語，讓逐字稿寫對")
                Spacer()
                Button("結束") {
                    recorder.stop()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { recorder.refresh() }
    }
}
