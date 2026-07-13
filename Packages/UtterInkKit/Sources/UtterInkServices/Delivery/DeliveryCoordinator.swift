import Foundation
import UtterInkCore

enum TargetValidation: Equatable, Sendable {
    case valid
    case unavailable
    case changed
}

enum TargetDispatch: Equatable, Sendable {
    case dispatched
    case unavailable
    case changed
    case failed
}

protocol TargetValidating: Sendable {
    func validate(targetID: DeliveryTargetID, token: EffectToken) async -> TargetValidation
    func revalidateAndDispatch(
        targetID: DeliveryTargetID,
        token: EffectToken
    ) async -> TargetDispatch
}

public actor DeliveryCoordinator: DeliveryService {
    private struct LeaseWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let pasteboard: any PasteboardAccess
    private let target: any TargetValidating
    private let onboardingSink: any OnboardingTestSink
    private let clock: any AppClock
    private let settleDelay: Duration

    private var leaseOwner: UUID?
    private var leaseWaiters: [LeaseWaiter] = []

    public init(
        pasteboard: PasteboardClient,
        target: TargetTracker,
        onboardingSink: any OnboardingTestSink,
        clock: any AppClock,
        settleDelay: Duration = .milliseconds(250)
    ) {
        self.pasteboard = pasteboard
        self.target = target
        self.onboardingSink = onboardingSink
        self.clock = clock
        self.settleDelay = settleDelay
    }

    init(
        pasteboard: any PasteboardAccess,
        target: any TargetValidating,
        onboardingSink: any OnboardingTestSink,
        clock: any AppClock,
        settleDelay: Duration = .milliseconds(250)
    ) {
        self.pasteboard = pasteboard
        self.target = target
        self.onboardingSink = onboardingSink
        self.clock = clock
        self.settleDelay = settleDelay
    }

    public func deliver(
        text: String,
        to target: DeliveryTarget,
        preference: DeliveryPreference,
        token: EffectToken
    ) async -> DeliveryOutcome {
        if target == .onboardingTest {
            guard !Task.isCancelled else {
                return .manualCopyRequired(.cancelled)
            }
            await onboardingSink.deliver(text, sessionID: token.sessionID)
            return .deliveredToOnboardingTest
        }

        if preference == .copyOnly {
            return await performDirectCopy(text: text, outcome: .copiedByPreference)
        }

        guard case let .external(targetID) = target else {
            return .manualCopyRequired(.deliveryTargetUnavailable)
        }

        return await performAutomaticPaste(text: text, targetID: targetID, token: token)
    }

    public func copyExplicitly(text: String, token: EffectToken) async -> DeliveryOutcome {
        await performDirectCopy(text: text, outcome: .copiedByUser)
    }

    private func performDirectCopy(
        text: String,
        outcome: DeliveryOutcome
    ) async -> DeliveryOutcome {
        let leaseID: UUID
        do {
            leaseID = try await acquireLease()
        } catch {
            return .manualCopyRequired(.cancelled)
        }
        defer { releaseLease(leaseID) }

        guard !Task.isCancelled else {
            return .manualCopyRequired(.cancelled)
        }
        let written = await pasteboard.replaceText(text)
        if written { return outcome }
        return Task.isCancelled
            ? .manualCopyRequired(.cancelled)
            : .manualCopyRequired(.deliveryPasteboardChanged)
    }

    private func performAutomaticPaste(
        text: String,
        targetID: DeliveryTargetID,
        token: EffectToken
    ) async -> DeliveryOutcome {
        let leaseID: UUID
        do {
            leaseID = try await acquireLease()
        } catch {
            return .manualCopyRequired(.cancelled)
        }
        defer { releaseLease(leaseID) }

        guard !Task.isCancelled else {
            return .manualCopyRequired(.cancelled)
        }
        guard case let .captured(snapshot) = await pasteboard.capture() else {
            return .manualCopyRequired(.deliveryPasteboardChanged)
        }
        guard !Task.isCancelled else {
            return .manualCopyRequired(.cancelled)
        }

        let validation = await target.validate(targetID: targetID, token: token)
        guard !Task.isCancelled else {
            return .manualCopyRequired(.cancelled)
        }
        switch validation {
        case .valid:
            break
        case .unavailable:
            return .manualCopyRequired(.deliveryTargetUnavailable)
        case .changed:
            return .manualCopyRequired(.deliveryTargetChanged)
        }

        guard !Task.isCancelled else {
            return .manualCopyRequired(.cancelled)
        }
        let writeResult = await pasteboard.compareAndWrite(
            text: text,
            expectedChangeCount: snapshot.changeCount
        )
        let ownedChangeCount: Int
        switch writeResult {
        case let .written(count):
            ownedChangeCount = count
        case .changed, .failed:
            return Task.isCancelled
                ? .manualCopyRequired(.cancelled)
                : .manualCopyRequired(.deliveryPasteboardChanged)
        }

        let outcome = await outcomeAfterWrite(targetID: targetID, token: token)
        _ = await pasteboard.guardedRestore(
            snapshot,
            ownedChangeCount: ownedChangeCount
        )
        return outcome
    }

    private func outcomeAfterWrite(
        targetID: DeliveryTargetID,
        token: EffectToken
    ) async -> DeliveryOutcome {
        guard !Task.isCancelled else {
            return .manualCopyRequired(.cancelled)
        }

        let dispatch = await target.revalidateAndDispatch(targetID: targetID, token: token)
        guard !Task.isCancelled else {
            return .manualCopyRequired(.cancelled)
        }
        switch dispatch {
        case .dispatched:
            break
        case .unavailable:
            return .manualCopyRequired(.deliveryTargetUnavailable)
        case .changed:
            return .manualCopyRequired(.deliveryTargetChanged)
        case .failed:
            return .manualCopyRequired(.deliveryDispatch)
        }

        do {
            try await clock.sleep(for: settleDelay)
        } catch {
            return .manualCopyRequired(.cancelled)
        }
        guard !Task.isCancelled else {
            return .manualCopyRequired(.cancelled)
        }
        return .pasteEventDispatched
    }

    private func acquireLease() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        if leaseOwner == nil {
            leaseOwner = id
            return id
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    leaseWaiters.append(LeaseWaiter(id: id, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            try Task.checkCancellation()
            return id
        } catch {
            if leaseOwner == id {
                releaseLease(id)
            }
            throw error
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = leaseWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = leaseWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseLease(_ id: UUID) {
        guard leaseOwner == id else { return }
        guard !leaseWaiters.isEmpty else {
            leaseOwner = nil
            return
        }
        let next = leaseWaiters.removeFirst()
        leaseOwner = next.id
        next.continuation.resume()
    }
}
