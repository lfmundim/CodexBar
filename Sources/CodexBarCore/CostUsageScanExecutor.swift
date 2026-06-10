import Foundation
import os

/// Cost-usage scans read and parse the full local session corpus synchronously and can run for
/// minutes on large archives. Executing that work inline on Swift's cooperative thread pool
/// starves every other async task in the process — menus freeze while the main thread sits idle —
/// and overlapping provider scans multiply both the pool pressure and the disk load. This
/// executor pins all corpus scans to a single serial utility queue off the cooperative pool, so
/// long scans cost one dedicated thread instead of the app's async runtime.
public enum CostUsageScanExecutor {
    public static let queueLabel = "com.steipete.codexbar.cost-usage-scan"

    private static let queue = DispatchQueue(label: queueLabel, qos: .utility)

    /// Runs `work` on the serial scan queue and bridges Swift task cancellation into the
    /// scanner's cooperative `checkCancellation` callbacks. Work that is still queued when the
    /// awaiting task is cancelled resumes immediately with `CancellationError` instead of
    /// waiting behind an in-flight scan.
    public static func run<T: Sendable>(
        _ work: @escaping @Sendable (_ checkCancellation: @escaping @Sendable () throws -> Void) throws -> T)
        async throws -> T
    {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let checkCancellation: @Sendable () throws -> Void = {
            if cancelled.withLock({ $0 }) {
                throw CancellationError()
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Result { try work(checkCancellation) })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}
