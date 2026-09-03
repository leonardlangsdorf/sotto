import AppKit
import SottoCore
import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    var settings: SottoCore.Settings {
        didSet {
            store.settings = settings
            onChange()
        }
    }
    var draftTerm = ""

    private let store: SettingsStore
    var onChange: () -> Void = {}
    var refinerAvailable = true
    var refinerUnavailableReason: String?

    init(store: SettingsStore) {
        self.store = store
        self.settings = store.settings
    }

    func addDraftTerm() {
        settings.vocabulary.add(draftTerm)
        draftTerm = ""
    }

    func remove(_ term: String) {
        settings.vocabulary.remove(term)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(model: SettingsModel) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sotto"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Dictation") {
                LabeledContent("Trigger") {
                    Text("Hold Right ⌘").foregroundStyle(.secondary)
                }
                Toggle("Clean up with on-device model", isOn: $model.settings.cleanupEnabled)
                    .disabled(!model.refinerAvailable)
                if let reason = model.refinerUnavailableReason {
                    Text("Cleanup unavailable: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.settings.cleanupEnabled {
                    LabeledContent("Maximum wait") {
                        Stepper(
                            value: $model.settings.refineMaximumWait, in: 5...60, step: 5
                        ) {
                            Text(String(format: "%.0f s", model.settings.refineMaximumWait))
                        }
                    }
                    Text("Cleanup removes filler and tightens phrasing, but costs roughly half a second per word — a long dictation takes several seconds. The raw transcript is inserted if it runs over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Raw transcripts arrive in about a third of a second, already punctuated and capitalized. Turn cleanup on when you want filler words removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Insertion") {
                Picker("Method", selection: $model.settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases, id: \.self) { method in
                        Text(method.label).tag(method)
                    }
                }
                if model.settings.insertionMethod == .paste {
                    LabeledContent("Clipboard restore delay") {
                        Stepper(
                            value: $model.settings.pasteboardRestoreDelay, in: 0.05...1.0, step: 0.05
                        ) {
                            Text(String(format: "%.2f s", model.settings.pasteboardRestoreDelay))
                        }
                    }
                    Text("Raise this if an app occasionally pastes your previous clipboard contents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Typing never touches the clipboard, but is slower and is ignored by a few apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    TextField("Add a name or term", text: $model.draftTerm)
                        .onSubmit(model.addDraftTerm)
                    Button("Add", action: model.addDraftTerm)
                        .disabled(model.draftTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if model.settings.vocabulary.terms.isEmpty {
                    Text("No terms yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.settings.vocabulary.terms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                model.remove(term)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("\(model.settings.vocabulary.terms.count) of \(Vocabulary.maxTerms). These bias recognition toward names and jargon — a longer list is not a better one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }
}
