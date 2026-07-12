import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 首次安装默认：⌥ 空格（未自定义前由 KeyboardShortcuts 使用该默认值）。
    static let toggleRecording = Self("toggleRecording", default: .init(.space, modifiers: [.option]))
}
