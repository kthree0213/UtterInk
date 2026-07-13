import Accessibility
import Foundation
import SwiftUI

struct UtterInkAccessibilityEvent: Equatable {
    let id = UUID()
    let message: String
}

private struct UtterInkAccessibilityAnnouncementModifier: ViewModifier {
    let message: String?

    func body(content: Content) -> some View {
        content.onChange(of: message) { _, message in
            guard let message, !message.isEmpty else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

private struct UtterInkAccessibilityEventModifier: ViewModifier {
    let event: UtterInkAccessibilityEvent?

    func body(content: Content) -> some View {
        content.onChange(of: event) { _, event in
            guard let event, !event.message.isEmpty else { return }
            AccessibilityNotification.Announcement(event.message).post()
        }
    }
}

extension View {
    func utterInkAccessibilityAnnouncement(_ message: String?) -> some View {
        modifier(UtterInkAccessibilityAnnouncementModifier(message: message))
    }

    func utterInkAccessibilityAnnouncement(
        _ event: UtterInkAccessibilityEvent?
    ) -> some View {
        modifier(UtterInkAccessibilityEventModifier(event: event))
    }
}
