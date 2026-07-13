import Observation
import SwiftUI
import UtterInkCore

@MainActor
@Observable
final class OutputModeSettingsViewModel {
    private(set) var modes: [OutputMode] = [.raw]
    private(set) var selectedModeID = OutputMode.rawID
    private(set) var isSaving = false
    private(set) var failureMessage: String?
    private(set) var accessibilityEvent: UtterInkAccessibilityEvent?

    @ObservationIgnored private let writer: SettingsMutationCoordinator

    init(settings: any SettingsStore) {
        writer = SettingsMutationCoordinator(store: settings)
    }

    init(settings: any SettingsStore, writer: SettingsMutationCoordinator) {
        self.writer = writer
    }

    func load() async {
        guard !isSaving else { return }
        do {
            publish(try await writer.current())
            failureMessage = nil
        } catch {
            failureMessage = "Output modes could not be loaded. Your current values were kept."
        }
    }

    func canUse(_ mode: OutputMode) -> Bool {
        mode == .raw || (
            mode.id != OutputMode.rawID
                && !mode.skipsPolishing
                && !mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    @discardableResult
    func add(title: String, instructions: String) async -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSaving, !cleanTitle.isEmpty, !cleanInstructions.isEmpty else {
            failureMessage = "A polish mode needs both a name and non-empty instructions."
            return false
        }

        let mode = OutputMode(
            id: UUID(),
            title: cleanTitle,
            skipsPolishing: false,
            instructions: cleanInstructions
        )
        return await mutate(
            failure: "The output mode could not be added.",
            success: "Output mode added."
        ) { settings in
            Self.repairRawInvariant(&settings)
            guard !settings.outputModes.contains(where: { $0.id == mode.id }) else { return }
            settings.outputModes.append(mode)
        }
    }

    @discardableResult
    func update(id: UUID, title: String, instructions: String) async -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSaving,
              id != OutputMode.rawID,
              !cleanTitle.isEmpty,
              !cleanInstructions.isEmpty else {
            failureMessage = id == OutputMode.rawID
                ? "Raw is built in and cannot be edited."
                : "A polish mode needs both a name and non-empty instructions."
            return false
        }

        return await mutate(
            failure: "The output mode could not be updated.",
            success: "Output mode updated."
        ) { settings in
            Self.repairRawInvariant(&settings)
            guard let index = settings.outputModes.firstIndex(where: { $0.id == id }) else {
                return
            }
            settings.outputModes[index] = OutputMode(
                id: id,
                title: cleanTitle,
                skipsPolishing: false,
                instructions: cleanInstructions
            )
        }
    }

    func delete(id: UUID) async {
        guard !isSaving else { return }
        guard id != OutputMode.rawID else {
            failureMessage = "Raw is built in and cannot be deleted."
            return
        }
        _ = await mutate(
            failure: "The output mode could not be deleted.",
            success: "Output mode deleted."
        ) { settings in
            Self.repairRawInvariant(&settings)
            settings.outputModes.removeAll { $0.id == id }
            if settings.selectedOutputModeID == id {
                settings.selectedOutputModeID = OutputMode.rawID
            }
        }
    }

    func select(id: UUID) async {
        guard !isSaving else { return }
        _ = await mutate(
            failure: "The output mode could not be selected.",
            success: "Output mode selected for future dictations."
        ) { settings in
            Self.repairRawInvariant(&settings)
            guard settings.outputModes.contains(where: { $0.id == id }) else { return }
            settings.selectedOutputModeID = id
        }
    }

    private func mutate(
        failure: String,
        success: String,
        _ mutation: @escaping @Sendable (inout UserSettings) -> Void
    ) async -> Bool {
        isSaving = true
        failureMessage = nil
        defer { isSaving = false }
        do {
            let saved = try await writer.update(mutation)
            publish(saved)
            accessibilityEvent = UtterInkAccessibilityEvent(message: success)
            return true
        } catch {
            failureMessage = failure
            return false
        }
    }

    private func publish(_ settings: UserSettings) {
        let repaired = Self.repairedModes(settings.outputModes)
        modes = repaired
        selectedModeID = repaired.contains(where: { $0.id == settings.selectedOutputModeID })
            ? settings.selectedOutputModeID
            : OutputMode.rawID
    }

    private nonisolated static func repairRawInvariant(_ settings: inout UserSettings) {
        settings.outputModes = repairedModes(settings.outputModes)
        if !settings.outputModes.contains(where: { $0.id == settings.selectedOutputModeID }) {
            settings.selectedOutputModeID = OutputMode.rawID
        }
    }

    private nonisolated static func repairedModes(_ source: [OutputMode]) -> [OutputMode] {
        var seen: Set<UUID> = [OutputMode.rawID]
        let custom = source.compactMap { mode -> OutputMode? in
            guard mode.id != OutputMode.rawID,
                  seen.insert(mode.id).inserted,
                  !mode.skipsPolishing,
                  !mode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return mode
        }
        return [.raw] + custom
    }
}

struct OutputModeSettingsView: View {
    @Bindable var model: OutputModeSettingsViewModel
    @State private var editorIsPresented = false
    @State private var editingID: UUID?
    @State private var title = ""
    @State private var instructions = ""

    var body: some View {
        Form {
            Section("Modes") {
                ForEach(model.modes) { mode in
                    HStack {
                        Button {
                            Task { await model.select(id: mode.id) }
                        } label: {
                            Image(systemName: model.selectedModeID == mode.id
                                ? "largecircle.fill.circle"
                                : "circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isSaving)
                        .accessibilityLabel("Select \(mode.title)")
                        .accessibilityValue(model.selectedModeID == mode.id ? "Selected" : "Not selected")
                        .accessibilityIdentifier("settings.outputModes.select.\(mode.id.uuidString.lowercased())")

                        VStack(alignment: .leading) {
                            Text(mode.title)
                            Text(mode == .raw
                                ? "Local transcript, no provider required"
                                : mode.instructions)
                                .lineLimit(2)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode == .raw {
                            Text("Built In").foregroundStyle(.secondary)
                        } else {
                            Button("Edit") { beginEditing(mode) }
                                .accessibilityIdentifier("settings.outputModes.edit.\(mode.id.uuidString.lowercased())")
                            Button("Delete", role: .destructive) {
                                Task { await model.delete(id: mode.id) }
                            }
                            .accessibilityIdentifier("settings.outputModes.delete.\(mode.id.uuidString.lowercased())")
                        }
                    }
                }
                Button("Add Polish Mode") { beginAdding() }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("settings.outputModes.add")
            }

            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error")
                    .accessibilityValue(failureMessage)
                    .accessibilityIdentifier("settings.outputModes.error")
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.outputModes")
        .utterInkAccessibilityAnnouncement(model.failureMessage.map { "Error: \($0)" })
        .utterInkAccessibilityAnnouncement(model.accessibilityEvent)
        .navigationTitle("Output Modes")
        .task { await model.load() }
        .sheet(isPresented: $editorIsPresented) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editingID == nil ? "Add Polish Mode" : "Edit Polish Mode")
                    .font(.title2.bold())
                TextField("Name", text: $title)
                    .accessibilityLabel("Polish Mode Name")
                    .accessibilityIdentifier("settings.outputModes.editor.name")
                TextField(
                    "Instructions",
                    text: $instructions,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .lineLimit(6...12)
                    .padding(8)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .accessibilityLabel("Instructions")
                    .accessibilityIdentifier("settings.outputModes.editor.instructions")
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { editorIsPresented = false }
                        .accessibilityIdentifier("settings.outputModes.editor.cancel")
                    Button("Save") { saveEditor() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("settings.outputModes.editor.save")
                }
            }
            .padding(24)
            .frame(width: 480)
            .accessibilityIdentifier("settings.outputModes.editor")
        }
    }

    private func beginAdding() {
        editingID = nil
        title = ""
        instructions = ""
        editorIsPresented = true
    }

    private func beginEditing(_ mode: OutputMode) {
        editingID = mode.id
        title = mode.title
        instructions = mode.instructions
        editorIsPresented = true
    }

    private func saveEditor() {
        let id = editingID
        let capturedTitle = title
        let capturedInstructions = instructions
        Task {
            let saved = if let id {
                await model.update(id: id, title: capturedTitle, instructions: capturedInstructions)
            } else {
                await model.add(title: capturedTitle, instructions: capturedInstructions)
            }
            if saved { editorIsPresented = false }
        }
    }
}
