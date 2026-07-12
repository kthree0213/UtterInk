import Cocoa
import KeyboardShortcuts

@MainActor
public class HotkeyManager: ObservableObject {
    public var onRecordingStart: (() -> Void)?
    public var onRecordingStop: (() -> Void)?
    private var isRecording = false

    public init() {}

    public func startListening() {
        KeyboardShortcuts.removeHandler(for: .toggleRecording)
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            guard let self = self else { return }
            let mode = UserDefaults.standard.string(forKey: "shortcutMode") ?? "toggle"
            
            if mode == "pushToTalk" {
                self.isRecording = true
                self.onRecordingStart?()
            } else {
                if self.isRecording {
                    self.isRecording = false
                    self.onRecordingStop?()
                } else {
                    self.isRecording = true
                    self.onRecordingStart?()
                }
            }
        }
        
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            guard let self = self else { return }
            let mode = UserDefaults.standard.string(forKey: "shortcutMode") ?? "toggle"
            
            if mode == "pushToTalk" && self.isRecording {
                self.isRecording = false
                self.onRecordingStop?()
            }
        }
    }
}
