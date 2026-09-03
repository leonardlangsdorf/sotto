import Testing
@testable import SottoCore

@Suite("Dictation state machine")
struct DictationMachineTests {
    let target: TargetPID = 4242

    @Test("Happy path runs press -> release -> transcript -> injected")
    func happyPath() {
        var m = DictationMachine()

        #expect(m.handle(.triggerPressed(target: target)) == [.startCapture])
        #expect(m.state == .recording(target: target))

        #expect(m.handle(.triggerReleased) == [.stopCaptureAndFinalize])
        #expect(m.state == .transcribing(target: target))

        let effects = m.handle(.transcriptReady("send it to Sarah"))
        #expect(effects == [.deliver(text: "send it to Sarah", target: target)])
        #expect(m.state == .injecting(target: target))

        #expect(m.handle(.injectionCompleted).isEmpty)
        #expect(m.state == .idle)
    }

    @Test("Delivered text is normalized")
    func normalizesBeforeDelivery() {
        var m = DictationMachine(state: .transcribing(target: target))
        let effects = m.handle(.transcriptReady("  hello   there\n world "))
        #expect(effects == [.deliver(text: "hello there world", target: target)])
    }

    @Test("Empty and whitespace-only transcripts never paste", arguments: ["", "   ", "\n\t "])
    func emptyTranscriptIsNoOp(text: String) {
        var m = DictationMachine(state: .transcribing(target: target))
        #expect(m.handle(.transcriptReady(text)) == [.notify(.emptyTranscript)])
        #expect(m.state == .idle)
    }

    @Test("Aborting while recording stops capture and reports")
    func abortWhileRecording() {
        var m = DictationMachine(state: .recording(target: target))
        #expect(m.handle(.abort(.secureInput)) == [.cancelCapture, .notify(.secureInput)])
        #expect(m.state == .idle)
    }

    @Test("Focus change during transcription discards without pasting")
    func abortWhileTranscribing() {
        var m = DictationMachine(state: .transcribing(target: target))
        #expect(m.handle(.abort(.focusChanged)) == [.notify(.focusChanged)])
        #expect(m.state == .idle)
    }

    @Test("Abort during injection returns to idle")
    func abortWhileInjecting() {
        var m = DictationMachine(state: .injecting(target: target))
        #expect(m.handle(.abort(.injectionFailed("no target"))) == [.notify(.injectionFailed("no target"))])
        #expect(m.state == .idle)
    }

    @Test("A second press while busy is ignored")
    func reentrantPressIgnored() {
        var m = DictationMachine(state: .recording(target: target))
        #expect(m.handle(.triggerPressed(target: 999)).isEmpty)
        #expect(m.state == .recording(target: target))
    }

    @Test("A stray release while idle is ignored")
    func strayReleaseIgnored() {
        var m = DictationMachine()
        #expect(m.handle(.triggerReleased).isEmpty)
        #expect(m.state == .idle)
    }

    @Test("Target survives the whole cycle")
    func targetIsCarriedThrough() {
        var m = DictationMachine()
        m.handle(.triggerPressed(target: 77))
        m.handle(.triggerReleased)
        #expect(m.state.target == 77)
        let effects = m.handle(.transcriptReady("ok"))
        #expect(effects == [.deliver(text: "ok", target: 77)])
    }
}

@Suite("Transcript assembly")
struct TranscriptTests {
    @Test("Fragments join into one normalized string")
    func assembles() {
        #expect(Transcript.assemble(["Hello", "there", "friend"]) == "Hello there friend")
    }

    @Test("Ragged fragment spacing collapses")
    func collapsesSpacing() {
        #expect(Transcript.assemble([" Hello ", "", "  there "]) == "Hello there")
    }

    @Test("Whitespace-only input yields empty")
    func whitespaceOnly() {
        #expect(Transcript.assemble(["  ", "\n"]).isEmpty)
    }
}

@Suite("Settings defaults")
struct SettingsDefaultTests {
    @Test("Cleanup is off by default so dictation stays fast")
    func cleanupDefaultsOff() {
        #expect(Settings.default.cleanupEnabled == false)
    }
}
