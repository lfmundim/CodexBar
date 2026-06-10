import Foundation
import os
import Testing
@testable import CodexBarCore

struct CostUsageScanExecutorTests {
    @Test
    func `runs work on the dedicated scan queue and returns its value`() async throws {
        let label = try await CostUsageScanExecutor.run { _ in
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(label == CostUsageScanExecutor.queueLabel)
    }

    @Test
    func `propagates thrown errors`() async {
        struct ScanFailure: Error {}
        await #expect(throws: ScanFailure.self) {
            try await CostUsageScanExecutor.run { _ -> Int in
                throw ScanFailure()
            }
        }
    }

    @Test
    func `serializes overlapping scans`() async throws {
        let state = OSAllocatedUnfairLock(initialState: (active: 0, maxActive: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await CostUsageScanExecutor.run { _ in
                        state.withLock {
                            $0.active += 1
                            $0.maxActive = max($0.maxActive, $0.active)
                        }
                        usleep(20000)
                        state.withLock { $0.active -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(state.withLock { $0.maxActive } == 1)
    }

    @Test
    func `cancellation reaches in-flight work through checkCancellation`() async {
        let workStarted = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await CostUsageScanExecutor.run { checkCancellation in
                workStarted.withLock { $0 = true }
                while true {
                    try checkCancellation()
                    usleep(5000)
                }
            }
        }
        while !workStarted.withLock({ $0 }) {
            usleep(1000)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func `work cancelled while queued resumes with CancellationError`() async {
        let blockerStarted = OSAllocatedUnfairLock(initialState: false)
        let releaseBlocker = OSAllocatedUnfairLock(initialState: false)
        let blocker = Task {
            try await CostUsageScanExecutor.run { _ in
                blockerStarted.withLock { $0 = true }
                while !releaseBlocker.withLock({ $0 }) {
                    usleep(2000)
                }
            }
        }
        while !blockerStarted.withLock({ $0 }) {
            usleep(1000)
        }

        let queued = Task {
            try await CostUsageScanExecutor.run { _ in
                Issue.record("queued work should not run after cancellation")
            }
        }
        queued.cancel()
        releaseBlocker.withLock { $0 = true }

        await #expect(throws: CancellationError.self) {
            try await queued.value
        }
        _ = try? await blocker.value
    }
}
