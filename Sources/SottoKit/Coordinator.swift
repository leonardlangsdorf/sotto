import AppKit
import Foundation
import SottoCore

enum AppStatus: Equatable {
    case startingUp
    case needsAccessibility
    case needsMicrophone
    case downloadingModel(fraction: Double)
    case ready
    case recording
    case working
    case failed(String)

    var canDictate: Bool { self == .ready }

    var summary: String {
        switch self {
        case .startingUp: return "Starting up…"
        case .needsAccessibility: return "Accessibility permission needed"
        case .needsMicrophone: return "Microphone permission needed"
        case .downloadingModel(let f): return "Downloading speech model… \(Int(f * 100))%"
        case .ready: return "Ready — hold Right ⌘ to dictate"
        case .recording: return "Listening…"
        case .working: return "Transcribing…"
        case .failed(let message): return message
        }
    }

    var symbolName: String {
        switch self {
        case .startingUp, .downloadingModel: return "waveform.badge.exclamationmark"
        case .needsAccessibility, .needsMicrophone, .failed: return "waveform.slash"
        case .ready: return "waveform"
        case .recording: return "waveform.badge.microphone"
        case .working: return "waveform.badge.magnifyingglass"
        }
    }
}

/// Owns the state machine and executes its effects against the real services.
@MainActor
final class Coordinator {
    private var machine = DictationMachine()
    private let tap = HotkeyTap()
    private let hud = HUDController()
    private let speech = SpeechService()
    private let refiner = DictationRefiner()
    private let injector: PasteboardInjector
    let store: SettingsStore

    private var level: Double = 0
    private var partial: String = ""

    private(set) var status: AppStatus = .startingUp {
        didSet {
            guard status != oldValue else { return }
            Log.lifecycle.info("status: \(self.status.summary, privacy: .public)")
            onStatusChange?(status)
        }
    }
    var onStatusChange: ((AppStatus) -> Void)?

    init(store: SettingsStore) {
        self.store = store
        self.injector = PasteboardInjector(
            restoreDelay: { store.settings.pasteboardRestoreDelay },
            method: { store.settings.insertionMethod })

        tap.onPress = { [weak self] in self?.triggerPressed() }
        tap.onRelease = { [weak self] in self?.triggerReleased() }
        speech.onLevel = { [weak self] level in self?.updateLevel(level) }
        speech.onPartial = { [weak self] text in self?.updatePartial(text) }
    }

    // MARK: - Startup

    func start() async {
        guard Permissions.hasAccessibility else {
            status = .needsAccessibility
            Permissions.requestAccessibility()
            pollForAccessibility()
            return
        }
        guard await ensureMicrophone() else {
            status = .needsMicrophone
            return
        }
        await ensureModel()
        guard status != .failed(status.summary) else { return }

        do {
            try tap.start()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        applySettings()
        await speech.prewarm()
        refiner.prewarm()
        Log.lifecycle.info(
            """
            ready — cleanup:\(self.refiner.isAvailable ? "available" : "unavailable", privacy: .public) \
            vocabulary:\(self.store.settings.vocabulary.terms.count, privacy: .public) terms
            """)
        status = .ready
    }

    func applySettings() {
        let settings = store.settings
        speech.localeIdentifier = settings.localeIdentifier
        speech.vocabulary = settings.vocabulary.terms
        refiner.isEnabled = settings.cleanupEnabled
        refiner.timeout = settings.refineTimeout
    }

    private func ensureMicrophone() async -> Bool {
        switch Permissions.microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await Permissions.requestMicrophone()
        default: return false
        }
    }

    private func ensureModel() async {
        let locale = Locale(identifier: store.settings.localeIdentifier)
        if await SpeechService.isModelInstalled(locale: locale) { return }

        status = .downloadingModel(fraction: 0)
        do {
            try await SpeechService.installModelIfNeeded(locale: locale) { [weak self] progress in
                self?.observe(progress)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private var progressObservation: NSKeyValueObservation?

    private func observe(_ progress: Progress) {
        progressObservation = progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, case .downloadingModel = self.status else { return }
                self.status = .downloadingModel(fraction: fraction)
            }
        }
    }

    /// Accessibility is granted outside the app, so watch for it rather than
    /// making the user relaunch.
    private func pollForAccessibility() {
        Task { @MainActor [weak self] in
            while self != nil, !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, self.status == .needsAccessibility else { return }
            await self.start()
        }
    }

    // MARK: - Hotkey

    private func triggerPressed() {
        guard status.canDictate else {
            hud.flash(status.summary)
            return
        }
        guard !Permissions.isSecureInputActive else {
            hud.flash(AbortReason.secureInput.userMessage)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        Log.dictation.info(
            "press — target: \(app.localizedName ?? "?", privacy: .public) (\(app.processIdentifier))")
        run(machine.handle(.triggerPressed(target: app.processIdentifier)))
    }

    private func triggerReleased() {
        run(machine.handle(.triggerReleased))
    }

    // MARK: - Effects

    private func run(_ effects: [DictationEffect]) {
        for effect in effects { run(effect) }
    }

    private func run(_ effect: DictationEffect) {
        switch effect {
        case .startCapture:
            level = 0
            partial = ""
            status = .recording
            hud.show(.recording(level: 0, partial: ""))
            applySettings()
            Task { @MainActor in
                do { try await speech.startCapture() }
                catch { run(machine.handle(.abort(.transcriptionFailed(error.localizedDescription)))) }
            }

        case .stopCaptureAndFinalize:
            status = .working
            hud.show(.transcribing)
            Task { @MainActor in
                do {
                    let raw = try await speech.finishAndTranscribe()
                    Log.dictation.debug("raw: \(raw, privacy: .private)")
                    let text = await refiner.refine(raw, vocabulary: store.settings.vocabulary.terms)
                    Log.dictation.debug("cleaned: \(text, privacy: .private)")
                    run(machine.handle(.transcriptReady(text)))
                } catch {
                    run(machine.handle(.abort(.transcriptionFailed(error.localizedDescription))))
                }
            }

        case .cancelCapture:
            Task { @MainActor in await speech.cancel() }

        case .deliver(let text, let target):
            Task { @MainActor in
                do {
                    try await injector.inject(text, into: target)
                    run(machine.handle(.injectionCompleted))
                    hud.hide()
                    status = .ready
                } catch PasteboardInjector.InjectError.focusChanged {
                    run(machine.handle(.abort(.focusChanged)))
                } catch {
                    run(machine.handle(.abort(.injectionFailed(error.localizedDescription))))
                }
            }

        case .notify(let reason):
            Log.dictation.info("aborted — \(reason.userMessage, privacy: .public)")
            hud.flash(reason.userMessage)
            status = .ready
        }
    }

    private func updateLevel(_ newLevel: Double) {
        guard case .recording = machine.state else { return }
        level = newLevel
        hud.show(.recording(level: level, partial: partial))
    }

    private func updatePartial(_ text: String) {
        guard case .recording = machine.state else { return }
        partial = text
        hud.show(.recording(level: level, partial: partial))
    }

    // MARK: - Diagnostics for the settings window

    var refinerAvailable: Bool { refiner.isAvailable }
    var refinerUnavailableReason: String? { refiner.unavailableReason }
}
