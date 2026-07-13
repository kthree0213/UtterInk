import AppKit
import Foundation
import UtterInkCore

struct PasteboardRepresentation: Equatable, Sendable {
    let type: String
    let data: Data

    init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

struct PasteboardItemSnapshot: Equatable, Sendable {
    let representations: [PasteboardRepresentation]

    init(representations: [PasteboardRepresentation]) {
        self.representations = representations
    }
}

struct PasteboardSnapshot: Equatable, Sendable, CustomDebugStringConvertible {
    let items: [PasteboardItemSnapshot]
    let changeCount: Int

    init(items: [PasteboardItemSnapshot], changeCount: Int) {
        self.items = items
        self.changeCount = changeCount
    }

    var debugDescription: String {
        let representationCount = items.reduce(into: 0) { count, item in
            count += item.representations.count
        }
        return "PasteboardSnapshot(items: \(items.count), representations: \(representationCount), payload: redacted)"
    }
}

enum PasteboardCaptureResult: Equatable, Sendable {
    case captured(PasteboardSnapshot)
    case unsafe
}

enum PasteboardWriteResult: Equatable, Sendable {
    case written(ownedChangeCount: Int)
    case changed
    case failed
}

protocol PasteboardAccess: Sendable {
    func capture() async -> PasteboardCaptureResult
    func replaceText(_ text: String) async -> Bool
    func compareAndWrite(text: String, expectedChangeCount: Int) async -> PasteboardWriteResult
    func guardedRestore(_ snapshot: PasteboardSnapshot, ownedChangeCount: Int) async -> Bool
}

@MainActor
protocol PasteboardPlatform: AnyObject {
    var changeCount: Int { get }
    var itemCount: Int? { get }
    func types(at index: Int) -> [String]?
    func data(at itemIndex: Int, type: String) -> Data?
    func replaceText(_ text: String) -> Bool
    func restore(_ items: [PasteboardItemSnapshot]) -> Bool
}

@MainActor
public final class PasteboardClient: PasteboardAccess, @unchecked Sendable {
    private static let maximumCaptureBytes = 16 * 1_024 * 1_024
    private static let maximumCaptureSeconds: TimeInterval = 0.5

    private let clock: any AppClock
    private let platform: any PasteboardPlatform

    public convenience init(clock: any AppClock) {
        self.init(clock: clock, platform: AppKitPasteboardPlatform())
    }

    init(clock: any AppClock, platform: any PasteboardPlatform) {
        self.clock = clock
        self.platform = platform
    }

    func capture() -> PasteboardCaptureResult {
        let startedAt = clock.now
        let startingCount = platform.changeCount

        guard withinBudget(since: startedAt),
              let itemCount = platform.itemCount,
              withinBudget(since: startedAt)
        else {
            return .unsafe
        }

        var items: [PasteboardItemSnapshot] = []
        items.reserveCapacity(itemCount)
        var totalBytes = 0

        for itemIndex in 0..<itemCount {
            guard withinBudget(since: startedAt),
                  let types = platform.types(at: itemIndex),
                  !types.isEmpty,
                  withinBudget(since: startedAt)
            else {
                return .unsafe
            }

            var representations: [PasteboardRepresentation] = []
            representations.reserveCapacity(types.count)
            for type in types {
                guard withinBudget(since: startedAt),
                      let data = platform.data(at: itemIndex, type: type),
                      !data.isEmpty,
                      withinBudget(since: startedAt),
                      let nextTotal = Self.checkedTotal(totalBytes, adding: data.count)
                else {
                    return .unsafe
                }
                totalBytes = nextTotal
                representations.append(PasteboardRepresentation(type: type, data: data))
            }
            items.append(PasteboardItemSnapshot(representations: representations))
        }

        guard platform.changeCount == startingCount, withinBudget(since: startedAt) else {
            return .unsafe
        }
        return .captured(PasteboardSnapshot(items: items, changeCount: startingCount))
    }

    func replaceText(_ text: String) -> Bool {
        guard !Task.isCancelled else { return false }
        return platform.replaceText(text)
    }

    func compareAndWrite(
        text: String,
        expectedChangeCount: Int
    ) -> PasteboardWriteResult {
        guard !Task.isCancelled else { return .failed }
        guard platform.changeCount == expectedChangeCount else { return .changed }
        guard platform.replaceText(text) else { return .failed }
        return .written(ownedChangeCount: platform.changeCount)
    }

    func guardedRestore(
        _ snapshot: PasteboardSnapshot,
        ownedChangeCount: Int
    ) -> Bool {
        guard platform.changeCount == ownedChangeCount else { return false }
        return platform.restore(snapshot.items)
    }

    static func checkedTotal(_ current: Int, adding amount: Int) -> Int? {
        guard current >= 0, amount >= 0 else { return nil }
        let (sum, overflow) = current.addingReportingOverflow(amount)
        guard !overflow, sum <= maximumCaptureBytes else { return nil }
        return sum
    }

    private func withinBudget(since startedAt: Date) -> Bool {
        let elapsed = clock.now.timeIntervalSince(startedAt)
        return elapsed >= 0 && elapsed <= Self.maximumCaptureSeconds
    }
}

@MainActor
private final class AppKitPasteboardPlatform: PasteboardPlatform {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }
    var itemCount: Int? { pasteboard.pasteboardItems?.count }

    func types(at index: Int) -> [String]? {
        guard let items = pasteboard.pasteboardItems, items.indices.contains(index) else {
            return nil
        }
        return items[index].types.map(\.rawValue)
    }

    func data(at itemIndex: Int, type: String) -> Data? {
        guard let items = pasteboard.pasteboardItems,
              items.indices.contains(itemIndex)
        else {
            return nil
        }
        return items[itemIndex].data(forType: NSPasteboard.PasteboardType(type))
    }

    func replaceText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([text as NSString])
    }

    func restore(_ items: [PasteboardItemSnapshot]) -> Bool {
        var restoredItems: [NSPasteboardItem] = []
        restoredItems.reserveCapacity(items.count)
        for item in items {
            let restored = NSPasteboardItem()
            for representation in item.representations {
                guard restored.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                ) else {
                    return false
                }
            }
            restoredItems.append(restored)
        }

        pasteboard.clearContents()
        if restoredItems.isEmpty { return true }
        return pasteboard.writeObjects(restoredItems)
    }
}
