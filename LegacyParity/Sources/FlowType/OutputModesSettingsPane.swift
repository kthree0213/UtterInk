import AppKit
import SwiftUI

/// 「设置 → 输出模式」：左侧模式列表（同模型供应商交互），右侧编辑名称与系统提示词。
struct OutputModesSettingsPane: View {
    @AppStorage(AppUILanguage.storageKey) private var uiLanguage = "en"
    @State private var modes: [OutputModeProfile] = []
    @State private var selectedModeId: UUID?

    private var sL10n: SettingsLocalization { SettingsLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }
    private var zh: Bool { AppUILanguage.isChinese(uiLanguage) }

    private var activeOutputModeId: UUID? {
        OutputModesStorage.activeModeId()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(sL10n.outputModesListTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(sL10n.outputModesListFootnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                List(selection: $selectedModeId) {
                    ForEach(modes) { mode in
                        HStack(alignment: .center, spacing: 6) {
                            Text(mode.displayTitle(useChinese: zh))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if activeOutputModeId == mode.id {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .imageScale(.small)
                                    Text(sL10n.speechModelStatusInUse)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(sL10n.speechModelStatusInUse)
                            } else {
                                Button {
                                    OutputModesStorage.setActiveModeId(mode.id)
                                } label: {
                                    Text(sL10n.speechModelUse)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color(nsColor: .controlAccentColor).opacity(0.2))
                                        )
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                                .help(sL10n.speechModelUse)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(Optional(mode.id))
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 292, height: 260)
                HStack(spacing: 8) {
                    Button(sL10n.outputModesAdd) {
                        addMode()
                    }
                    Button(sL10n.outputModesDelete, role: .destructive) {
                        deleteSelectedMode()
                    }
                    .disabled(selectedModeId == nil || (selectedModeId.map { OutputModesStorage.isBuiltInRaw($0) } ?? false))
                }
            }
            .frame(width: 308, alignment: .topLeading)
            .fixedSize(horizontal: true, vertical: false)

            Form {
                Text(sL10n.outputModesIntro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if modes.isEmpty {
                    Text(sL10n.outputModesSelectOnLeft)
                        .foregroundStyle(.secondary)
                } else if let mid = selectedModeId, let mode = modes.first(where: { $0.id == mid }) {
                    let locked = OutputModesStorage.isBuiltInRaw(mid)
                    if locked {
                        LabeledContent(sL10n.outputModesNameLabel) {
                            Text(mode.displayTitle(useChinese: zh))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(sL10n.outputModesRawHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField(sL10n.outputModesNameLabel, text: bindingTitle(for: mid))
                            .frame(maxWidth: 480, alignment: .leading)
                        Text(sL10n.outputModesPromptLabel)
                            .font(.headline)
                            .padding(.top, 4)
                        systemPromptEditor(modeId: mid)
                        if promptIsEffectivelyEmpty(modeId: mid) {
                            Text(sL10n.outputModesPromptEmptyHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Text(sL10n.outputModesSelectOnLeft)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .layoutPriority(1)
            .frame(minWidth: 480, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            reload(syncSelection: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .outputModesDidChange)) { _ in
            reload(syncSelection: false)
        }
    }

    private func bindingTitle(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                modes.first(where: { $0.id == id })?.title ?? ""
            },
            set: { newValue in
                guard let i = modes.firstIndex(where: { $0.id == id }) else { return }
                var copy = modes
                copy[i].title = newValue
                modes = copy
                OutputModesStorage.saveModes(modes)
            }
        )
    }

    private func bindingPrompt(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                modes.first(where: { $0.id == id })?.systemPrompt ?? ""
            },
            set: { newValue in
                guard let i = modes.firstIndex(where: { $0.id == id }) else { return }
                var copy = modes
                copy[i].systemPrompt = newValue
                modes = copy
                OutputModesStorage.saveModes(modes)
            }
        )
    }

    private func promptIsEffectivelyEmpty(modeId: UUID) -> Bool {
        (modes.first(where: { $0.id == modeId })?.systemPrompt ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    @ViewBuilder
    private func systemPromptEditor(modeId: UUID) -> some View {
        let isEmpty = promptIsEffectivelyEmpty(modeId: modeId)
        ZStack(alignment: .topLeading) {
            TextEditor(text: bindingPrompt(for: modeId))
                .font(.system(.body, design: .default))
                .frame(minHeight: 200, maxHeight: 360)
                .scrollContentBackground(.hidden)
                .padding(8)
            if isEmpty {
                Text(sL10n.outputModesPromptPlaceholder)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
                    .textSelection(.disabled)
                    .accessibilityHidden(true)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: isEmpty ? .controlBackgroundColor : .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.35))
        )
        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .topLeading)
    }

    private func reload(syncSelection: Bool) {
        modes = OutputModesStorage.loadModes()
        if syncSelection {
            selectedModeId = OutputModesStorage.activeModeId() ?? modes.first?.id
        } else {
            if let s = selectedModeId, !modes.contains(where: { $0.id == s }) {
                selectedModeId = OutputModesStorage.activeModeId() ?? modes.first?.id
            }
        }
    }

    private func addMode() {
        var list = OutputModesStorage.loadModes()
        let new = OutputModeProfile(
            id: UUID(),
            title: sL10n.outputModesNewDefaultTitle,
            skipsLLM: false,
            systemPrompt: ""
        )
        list.append(new)
        OutputModesStorage.saveModes(list)
        OutputModesStorage.setActiveModeId(new.id)
        modes = list
        selectedModeId = new.id
    }

    private func deleteSelectedMode() {
        guard let id = selectedModeId, !OutputModesStorage.isBuiltInRaw(id) else { return }
        OutputModesStorage.deleteMode(id: id)
        modes = OutputModesStorage.loadModes()
        selectedModeId = OutputModesStorage.activeModeId() ?? modes.first?.id
    }
}
