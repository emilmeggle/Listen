import AppKit
import SwiftUI
import Combine

// Listen — menu bar app that records system audio (and optionally the mic),
// transcribes it live and on-device via the `yap` CLI (Apple SpeechAnalyzer),
// and hands the transcript to any LLM.

extension Notification.Name {
    static let llmlResize = Notification.Name("llmlisten.resize")
}

// MARK: - Settings

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var saveDirPath: String { didSet { d.set(saveDirPath, forKey: "saveDirPath") } }
    @Published var format: String { didSet { d.set(format, forKey: "format") } }          // md | txt | srt
    @Published var localeID: String { didSet { d.set(localeID, forKey: "localeID") } }    // de-DE | en-US
    @Published var includeMic: Bool { didSet { d.set(includeMic, forKey: "includeMic") } }

    private init() {
        saveDirPath = d.string(forKey: "saveDirPath")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        format = d.string(forKey: "format") ?? "md"
        let stored = d.string(forKey: "localeID")
        localeID = (stored?.isEmpty ?? true) ? "de-DE" : stored!
        includeMic = d.object(forKey: "includeMic") as? Bool ?? true
    }

    var saveDirURL: URL { URL(fileURLWithPath: saveDirPath, isDirectory: true) }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return saveDirPath.hasPrefix(home)
            ? "~" + saveDirPath.dropFirst(home.count)
            : saveDirPath
    }

    var languageFlag: String { localeID == "de-DE" ? "🇩🇪" : "🇺🇸" }

    func toggleLanguage() {
        localeID = localeID == "de-DE" ? "en-US" : "de-DE"
    }
}

// MARK: - Recorder engine

final class Recorder: ObservableObject {
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    @Published var wordCount = 0
    @Published var statusMessage = "Ready"

    private var proc: Process?
    private var userStopped = false
    private var startDate: Date?
    private var restartCount = 0
    private var callMode = true
    private var format = "md"
    private var out: FileHandle?
    private var lineBuffer = ""
    private var stderrTail = ""
    private var uiTimer: Timer?
    private var stopTimer: Timer?

    private let maxDuration: TimeInterval = 2 * 60 * 60
    private let d = UserDefaults.standard

    var transcriptURL: URL? {
        get { d.string(forKey: "lastTranscript").map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue?.path, forKey: "lastTranscript") }
    }

    var elapsedString: String {
        let e = Int(elapsed)
        return e >= 3600
            ? String(format: "%d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60)
            : String(format: "%d:%02d", e / 60, e % 60)
    }

    private func yapPath() -> String? {
        ["/opt/homebrew/bin/yap", "/usr/local/bin/yap"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Start / stop

    func start() {
        guard !recording else { return }
        guard let yap = yapPath() else {
            alert("yap not found", "Listen needs the yap CLI.\n\nInstall it with:  brew install yap")
            return
        }
        let settings = Settings.shared
        callMode = settings.includeMic
        format = settings.format

        let dir = settings.saveDirURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        let stamp = df.string(from: Date())
        let url = dir.appendingPathComponent("\(callMode ? "call" : "audio")-\(stamp).\(settings.format)")

        var header = ""
        if format == "md" {
            header = "# \(callMode ? "Call" : "System audio") recording — \(stamp)\n"
                + "Mode: \(callMode ? "system + mic" : "system only") · Language: \(settings.localeID)\n\n"
        } else if format == "txt" {
            header = "\(callMode ? "Call" : "System audio") recording — \(stamp)\n\n"
        } // srt: no header, the file must start with the first cue
        FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        guard let handle = try? FileHandle(forWritingTo: url) else {
            alert("Could not create transcript file", url.path)
            return
        }
        handle.seekToEndOfFile()

        transcriptURL = url
        out = handle
        wordCount = 0
        restartCount = 0
        userStopped = false
        lineBuffer = ""
        stderrTail = ""
        elapsed = 0
        startDate = Date()
        recording = true
        statusMessage = "Recording"

        launchYap(yap)

        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let s = self.startDate else { return }
            self.elapsed = Date().timeIntervalSince(s)
        }
        stopTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            self?.stop(reason: "2 h limit reached")
        }
    }

    private func launchYap(_ path: String) {
        let settings = Settings.shared
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)

        let sub = callMode ? "listen-and-dictate" : "listen"
        let labels = callMode ? ["--mic-label", "Me", "--system-label", "Them"] : []
        var args: [String]
        switch format {
        case "srt":
            args = [sub, "--srt", "-m", "200"] + labels
        default: // md / txt — VTT for speaker labels in call mode, plain text otherwise
            args = callMode ? [sub, "--vtt", "-m", "200"] + labels : [sub, "--txt"]
        }
        args += ["-l", settings.localeID]
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.stderrTail = String((self!.stderrTail + s).suffix(800)) }
        }
        p.terminationHandler = { [weak self] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.procEnded() }
        }

        do {
            try p.run()
            proc = p
        } catch {
            recording = false
            alert("Could not start yap", error.localizedDescription)
            cleanupAfterStop(reason: "failed to start")
        }
    }

    private func procEnded() {
        proc = nil
        guard recording else { return }
        if userStopped {
            cleanupAfterStop(reason: nil)
            return
        }
        let runtime = Date().timeIntervalSince(startDate ?? Date())
        // Died almost immediately on first launch → almost certainly a permission problem.
        if restartCount == 0 && runtime < 5 {
            recording = false
            cleanupAfterStop(reason: "could not start")
            if stderrTail.lowercased().contains("permission") || stderrTail.isEmpty {
                permissionAlert()
            } else {
                alert("Recording could not start", "yap exited immediately.\n\nDetails: " + stderrTail)
            }
            return
        }
        if restartCount < 5 && runtime < maxDuration, let yap = yapPath() {
            restartCount += 1
            appendText(format == "md" ? "\n*[transcription resumed after an interruption]*\n\n" : "\n[resumed after an interruption]\n\n")
            launchYap(yap)
        } else {
            cleanupAfterStop(reason: "stopped unexpectedly")
        }
    }

    func stop(reason: String? = nil) {
        guard recording else { return }
        userStopped = true
        statusMessage = "Stopping…"
        if let p = proc, p.isRunning {
            p.interrupt() // SIGINT = Ctrl-C, lets yap flush and exit cleanly
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if let p = self?.proc, p.isRunning { p.terminate() }
            }
        } else {
            cleanupAfterStop(reason: reason)
        }
    }

    private func cleanupAfterStop(reason: String?) {
        recording = false
        uiTimer?.invalidate(); uiTimer = nil
        stopTimer?.invalidate(); stopTimer = nil
        if !lineBuffer.isEmpty { processLine(lineBuffer); lineBuffer = "" }
        try? out?.close(); out = nil
        let copied = copyTranscriptToClipboard()
        var msg = "Saved · \(wordCount) words"
        if copied { msg += " · copied" }
        if let r = reason { msg += " (\(r))" }
        statusMessage = msg
    }

    // MARK: Transcript ingestion

    private func ingest(_ chunk: String) {
        lineBuffer += chunk
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: nl)...])
            processLine(line)
        }
    }

    private func processLine(_ raw: String) {
        var line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
                                            with: "", options: .regularExpression)
        if let r = line.range(of: "\r", options: .backwards) {
            line = String(line[r.upperBound...]) // keep only the final content of overwritten lines
        }
        if format == "srt" { // pass through verbatim so the file stays a valid subtitle file
            appendText(line + "\n")
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.contains("-->") && Int(t) == nil {
                wordCount += t.split(separator: " ").count
            }
            return
        }
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        var text = t
        if callMode { // VTT output: skip structural lines, turn voice tags into speaker prefixes
            if t == "WEBVTT" || t.contains("-->") || Int(t) != nil { return }
            if let tag = t.range(of: "^<v ([^>]*)>", options: .regularExpression) {
                let label = t[tag].dropFirst(3).dropLast(1)
                let body = String(t[tag.upperBound...]).replacingOccurrences(of: "</v>", with: "")
                text = format == "md" ? "**\(label):** \(body)" : "\(label): \(body)"
            }
        }
        appendText(text + "\n\n")
        wordCount += text.split(separator: " ").count
    }

    private func appendText(_ s: String) {
        if let data = s.data(using: .utf8) { out?.write(data) }
    }

    // MARK: Transcript access

    func lastTranscript() -> URL? {
        if let u = transcriptURL, FileManager.default.fileExists(atPath: u.path) { return u }
        let files = (try? FileManager.default.contentsOfDirectory(at: Settings.shared.saveDirURL,
                     includingPropertiesForKeys: nil)) ?? []
        return files
            .filter {
                $0.lastPathComponent.range(of: #"^(call|audio)-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}\.(md|txt|srt)$"#,
                                           options: .regularExpression) != nil
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    @discardableResult
    func copyTranscriptToClipboard() -> Bool {
        guard let url = lastTranscript(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    // MARK: Claude handoff

    func openInClaude() {
        guard copyTranscriptToClipboard() else { return }
        let desktop = "/Applications/Claude.app"
        if FileManager.default.fileExists(atPath: desktop) {
            NSWorkspace.shared.open(URL(fileURLWithPath: desktop))
        } else {
            NSWorkspace.shared.open(URL(string: "https://claude.ai/new")!)
        }
        statusMessage = "Copied — press ⌘V in Claude"
    }

    // MARK: Alerts

    private func permissionAlert() {
        let a = NSAlert()
        a.messageText = "One step left: permission + relaunch"
        a.informativeText = "macOS applies the recording permission only to a freshly started app.\n\n"
            + "1. Enable Listen under System Settings → Privacy & Security → Screen & System Audio Recording\n"
            + "2. Relaunch Listen\n\n"
            + "Already granted it? Then just relaunch."
        a.addButton(withTitle: "Relaunch Listen")
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            relaunch()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        default:
            break
        }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Visual effect background

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.state = .active
        v.blendingMode = .behindWindow
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Card UI

struct CardView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings = Settings.shared
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsPane(settings: settings, onBack: { showSettings = false })
            } else {
                mainPane
            }
        }
        .padding(16)
        .frame(width: 272)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .onChange(of: showSettings) { NotificationCenter.default.post(name: .llmlResize, object: nil) }
        .onChange(of: recorder.recording) { NotificationCenter.default.post(name: .llmlResize, object: nil) }
    }

    var mainPane: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Listen").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }

            // Language · Record · Mic
            HStack(spacing: 24) {
                Button { settings.toggleLanguage() } label: {
                    Text(settings.languageFlag)
                        .font(.system(size: 17))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .disabled(recorder.recording)
                .opacity(recorder.recording ? 0.4 : 1)
                .help("Transcription language — click to switch")

                Button {
                    recorder.recording ? recorder.stop() : recorder.start()
                } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(red: 1.00, green: 0.36, blue: 0.32),
                                         Color(red: 0.82, green: 0.15, blue: 0.13)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(width: 66, height: 66)
                            .shadow(color: Color.red.opacity(recorder.recording ? 0.45 : 0.30),
                                    radius: recorder.recording ? 10 : 7, y: 3)
                        Circle()
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            .frame(width: 66, height: 66)
                        if recorder.recording {
                            RoundedRectangle(cornerRadius: 4.5)
                                .fill(.white)
                                .frame(width: 21, height: 21)
                        } else {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                                .frame(width: 52, height: 52)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button { settings.includeMic.toggle() } label: {
                    Image(systemName: settings.includeMic ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(settings.includeMic ? Color.accentColor : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .disabled(recorder.recording)
                .opacity(recorder.recording ? 0.4 : 1)
                .help(settings.includeMic ? "Microphone on (call mode)" : "Microphone off (system audio only)")
            }

            // Status
            if recorder.recording {
                VStack(spacing: 2) {
                    Text(recorder.elapsedString)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("\(recorder.wordCount) words · \(settings.languageFlag)\(settings.includeMic ? " · mic" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(recorder.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            // Action row
            HStack(spacing: 0) {
                cardAction("folder", "Recordings") {
                    NSWorkspace.shared.open(settings.saveDirURL)
                }
                cardAction("doc.text", "Last", disabled: recorder.lastTranscript() == nil) {
                    if let url = recorder.lastTranscript() { NSWorkspace.shared.open(url) }
                }
                cardAction("sparkles", "Open in Claude", disabled: recorder.lastTranscript() == nil) {
                    recorder.openInClaude()
                }
            }
        }
    }

    func cardAction(_ icon: String, _ title: String, disabled: Bool = false,
                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
        .disabled(disabled)
    }
}

struct SettingsPane: View {
    @ObservedObject var settings: Settings
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("SAVE TO").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                HStack {
                    Text(settings.displayPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") { pickFolder() }
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("FORMAT").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Picker("", selection: $settings.format) {
                    Text("Markdown (.md)").tag("md")
                    Text("Plain Text (.txt)").tag("txt")
                    Text("Subtitles (.srt)").tag("srt")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .controlSize(.small)
            }

            Divider()

            HStack {
                Text("v1.2").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Listen") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveDirURL
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirPath = url.path
        }
    }
}

// MARK: - Borderless card panel (instant, no popover lag/arrow)

final class CardPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        contentView = content
    }
    override var canBecomeKey: Bool { true }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: CardPanel!
    var hostView: NSHostingView<CardView>!
    let recorder = Recorder()
    var cancellable: AnyCancellable?
    var clickMonitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        setIdleIcon()

        hostView = NSHostingView(rootView: CardView(recorder: recorder))
        panel = CardPanel(content: hostView)

        cancellable = recorder.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusButton() }

        NotificationCenter.default.addObserver(forName: .llmlResize, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                if self?.panel.isVisible == true { self?.layoutPanel() }
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        if recorder.recording { recorder.stop() }
    }

    // MARK: Panel show/hide

    @objc func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    func showPanel() {
        layoutPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    func layoutPanel() {
        guard let button = statusItem.button, let bwin = button.window else { return }
        hostView.layoutSubtreeIfNeeded()
        let size = hostView.fittingSize
        let btnRect = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        var x = btnRect.midX - size.width / 2
        let y = btnRect.minY - size.height - 2 // 2 pt below the menu bar
        if let screen = bwin.screen ?? NSScreen.main {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: Status item appearance

    func setIdleIcon() {
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle.fill",
                                           accessibilityDescription: "Listen")
    }

    func refreshStatusButton() {
        // Runs after objectWillChange, so read state on the next runloop pass.
        DispatchQueue.main.async { [self] in
            if recorder.recording {
                statusItem.button?.image = nil
                let s = NSMutableAttributedString(string: "● ", attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.menuBarFont(ofSize: 0),
                ])
                s.append(NSAttributedString(string: recorder.elapsedString,
                                            attributes: [.font: NSFont.menuBarFont(ofSize: 0)]))
                statusItem.button?.attributedTitle = s
            } else if statusItem.button?.image == nil {
                setIdleIcon()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
