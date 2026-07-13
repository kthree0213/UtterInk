import Observation
import SwiftUI
import UtterInkCore

struct RecognitionLanguageChoice: Identifiable, Equatable {
    let code: String
    let title: String
    var id: String { code }
}

@MainActor
@Observable
final class RecognitionLanguageSettingsViewModel {
    static let fixedChoices = [RecognitionLanguageChoice(code: "en", title: "English")]

    private(set) var configuration = UserSettings.p0Default.recognition
    private(set) var isSaving = false
    private(set) var failureMessage: String?
    let failureSymbol = "exclamationmark.triangle.fill"

    @ObservationIgnored private let writer: SettingsMutationCoordinator

    init(settings: any SettingsStore) {
        writer = SettingsMutationCoordinator(store: settings)
    }

    init(settings: any SettingsStore, writer: SettingsMutationCoordinator) {
        self.writer = writer
    }

    var effectiveChoice: String {
        switch configuration {
        case .automatic:
            return "Automatic"
        case let .fixed(code):
            let title = Self.fixedChoices.first { $0.code == code }?.title ?? code.uppercased()
            return "\(title) (\(code))"
        }
    }

    func load() async {
        guard !isSaving else { return }
        do {
            configuration = try await writer.current().recognition
            failureMessage = nil
        } catch {
            failureMessage = "Recognition language could not be loaded. Your current choice was kept."
        }
    }

    func setAutomatic() async {
        await save(.automatic)
    }

    func setFixedLanguage(code: String) async {
        guard Self.fixedChoices.contains(where: { $0.code == code }) else { return }
        await save(.fixed(languageCode: code))
    }

    private func save(_ choice: RecognitionConfiguration) async {
        guard !isSaving, choice != configuration else { return }
        isSaving = true
        failureMessage = nil
        do {
            let saved = try await writer.update { $0.recognition = choice }
            configuration = saved.recognition
        } catch {
            failureMessage = "Recognition language could not be saved. Your current choice was kept."
        }
        isSaving = false
    }
}

struct RecognitionLanguageSettingsView: View {
    @Bindable var model: RecognitionLanguageSettingsViewModel

    var body: some View {
        Form {
            Section("Recognition Language") {
                Picker(
                    "Language Detection",
                    selection: Binding(
                        get: {
                            switch model.configuration {
                            case .automatic: return ""
                            case let .fixed(code): return code
                            }
                        },
                        set: { code in
                            Task {
                                if code.isEmpty {
                                    await model.setAutomatic()
                                } else {
                                    await model.setFixedLanguage(code: code)
                                }
                            }
                        }
                    )
                ) {
                    Text("Automatic").tag("")
                    ForEach(RecognitionLanguageSettingsViewModel.fixedChoices) { choice in
                        Text(choice.title).tag(choice.code)
                    }
                }
                Text("Current effective choice: \(model.effectiveChoice)")
                    .foregroundStyle(.secondary)
            }
            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: model.failureSymbol)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isSaving)
        .navigationTitle("Recognition Language")
        .task { await model.load() }
    }
}
