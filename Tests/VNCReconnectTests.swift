import XCTest
import Foundation
import CLibVNCClient

private func completePixelUpdate(_ client: VNCClientOperations.Client) {
    vncGotFrameBufferUpdate(client, 0, 0, client.pointee.width, client.pointee.height)
    vncFinishedFrameBufferUpdate(client)
}

private final class RecordedEvents {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class ManualScheduler {
    struct Job { let queue: DispatchQueue; let delay: TimeInterval; let work: DispatchWorkItem }
    private let lock = NSLock()
    private var jobs: [Job] = []
    var onSchedule: (() -> Void)?
    var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return jobs.map(\.delay) }
    func schedule(_ queue: DispatchQueue, _ delay: TimeInterval, _ work: DispatchWorkItem) {
        lock.lock()
        jobs.append(Job(queue: queue, delay: delay, work: work))
        lock.unlock()
        onSchedule?()
    }
    @discardableResult func take() -> Job {
        lock.lock(); defer { lock.unlock() }
        precondition(!jobs.isEmpty, "expected one owned scheduled item")
        return jobs.removeFirst()
    }
    func runNext() {
        let job = take()
        job.queue.sync { job.work.perform() }
    }
}

private final class FakeNative {
    private let lock = NSLock()
    private var outcomes: [Bool]
    private var polls: [Bool]
    private var live: Set<UInt> = []
    private var allocations = 0
    private var releases = 0
    private var failedInitReleases = 0
    private var duplicateReleases = 0
    private var peakLive = 0
    private var timeouts: [(UInt32, UInt32)] = []
    private var pollIntervals: [UInt32] = []
    private var buffers: Set<UInt> = []
    private var buffersAllocated = 0
    private var buffersReleased = 0
    private var duplicateBufferReleases = 0
    private var allocationRequests: [Int] = []
    var allocateBeforeFailure = false
    // Existing lifecycle cases model a complete initial update during init.
    // First-frame cases turn this off and deliver the actual callback later.
    var completeDuringInitialize = true
    var beforeInitialize: (() -> Void)?
    var afterFramebufferAllocation: (() -> Void)?
    var beforePoll: ((VNCClientOperations.Client) -> Void)?

    init(outcomes: [Bool] = [true], polls: [Bool] = [false]) {
        self.outcomes = outcomes; self.polls = polls
    }
    var counts: (allocations: Int, releases: Int, failed: Int, duplicate: Int, live: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (allocations, releases, failedInitReleases, duplicateReleases, live.count, peakLive)
    }
    var observedTimeouts: [(UInt32, UInt32)] { lock.lock(); defer { lock.unlock() }; return timeouts }
    var observedPollIntervals: [UInt32] { lock.lock(); defer { lock.unlock() }; return pollIntervals }
    var observedAllocationRequests: [Int] { lock.lock(); defer { lock.unlock() }; return allocationRequests }
    var bufferCounts: (allocated: Int, released: Int, live: Int, duplicate: Int) {
        lock.lock(); defer { lock.unlock() }
        return (buffersAllocated, buffersReleased, buffers.count, duplicateBufferReleases)
    }
    private func release(_ client: VNCClientOperations.Client, failed: Bool) {
        lock.lock()
        let owned = live.remove(UInt(bitPattern: client)) != nil
        if !owned { duplicateReleases += 1 }
        if owned { releases += 1; if failed { failedInitReleases += 1 } }
        lock.unlock()
        // Refuse a duplicate before dereferencing freed memory. XCTest checks
        // this observable counter; the fixture never deliberately double-frees.
        if owned { VNCClientOperations.release(client) }
    }
    var operations: VNCClientOperations {
        VNCClientOperations(make: { [self] config in
            // Allocation/tag cleanup is real LibVNCClient; no native connect,
            // socket, input, server message or external target is ever called.
            guard let client = rfbGetClient(config.bitsPerSample, config.samplesPerPixel, config.bytesPerPixel) else { return nil }
            lock.lock()
            allocations += 1; live.insert(UInt(bitPattern: client)); peakLive = max(peakLive, live.count)
            lock.unlock()
            return client
        }, initialize: { [self] client in
            beforeInitialize?()
            lock.lock()
            timeouts.append((client.pointee.connectTimeout, client.pointee.readTimeout))
            let success = outcomes.isEmpty ? true : outcomes.removeFirst()
            lock.unlock()
            if success || allocateBeforeFailure {
                client.pointee.width = 2; client.pointee.height = 2
                client.pointee.format.bitsPerPixel = 32
                if vncMallocFrameBuffer(client) == 0 {
                    release(client, failed: true)
                    return false
                }
                afterFramebufferAllocation?()
                if completeDuringInitialize { completePixelUpdate(client) }
            }
            if !success {
                release(client, failed: true) // C consumes client but NOT frameBuffer
                return false
            }
            return true
        }, cleanup: { [self] in release($0, failed: false) },
        poll: { [self] client, interval in
            beforePoll?(client)
            lock.lock(); defer { lock.unlock() }
            pollIntervals.append(interval)
            return polls.isEmpty ? true : polls.removeFirst()
        }, incrementalUpdate: { _ in }, allocateFramebuffer: { [self] size in
            lock.lock(); allocationRequests.append(size); lock.unlock()
            // The owned fixture never allocates a server-sized large buffer,
            // even if a regression incorrectly reaches the allocation seam.
            guard size <= 1024 else { return nil }
            guard let buffer = malloc(size)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            lock.lock(); buffers.insert(UInt(bitPattern: buffer)); buffersAllocated += 1; lock.unlock()
            return buffer
        }, freeFramebuffer: { [self] buffer in
            lock.lock()
            let owned = buffers.remove(UInt(bitPattern: buffer)) != nil
            if owned { buffersReleased += 1 } else { duplicateBufferReleases += 1 }
            lock.unlock()
            if owned { free(buffer) }
        })
    }
}

final class VNCReconnectTests: XCTestCase {
    func testFailedRetriesContinueAndRecoverWithBoundedBackoff() async throws {
        let native = FakeNative(outcomes: [true, false, false, true])
        let clock = ManualScheduler()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        try await bridge.connect()
        XCTAssertEqual(clock.delays, [0])
        clock.runNext() // actual message-loop loss
        XCTAssertEqual(clock.delays, [2])
        clock.runNext() // first failed native initialization
        XCTAssertEqual(clock.delays, [4])
        clock.runNext() // second failure must still schedule a retry
        XCTAssertEqual(clock.delays, [6])
        clock.runNext()
        XCTAssertTrue(bridge.connectionState.isConnected)
        XCTAssertEqual(bridge.framebufferWidth, 2)
        XCTAssertEqual(clock.delays, [0])
        XCTAssertEqual(native.counts.allocations, 4)
        XCTAssertEqual(native.counts.failed, 2)
        XCTAssertEqual(native.counts.peak, 1)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.releases, 4)
        XCTAssertEqual(native.counts.duplicate, 0)
        XCTAssertEqual(native.bufferCounts.live, 0)
        XCTAssertEqual(native.bufferCounts.allocated, native.bufferCounts.released)
        XCTAssertEqual(native.bufferCounts.duplicate, 0)
    }

    func testExhaustionCleansClientAndDoesNotScheduleAnotherAttempt() async throws {
        var config = VNCConfiguration(); config.maxReconnectAttempts = 2
        let native = FakeNative(outcomes: [true, false, false]); let clock = ManualScheduler()
        let bridge = VNCBridge(config: config, operations: native.operations, schedule: clock.schedule)
        try await bridge.connect()
        clock.runNext(); clock.runNext(); clock.runNext()
        XCTAssertEqual(clock.delays, [])
        XCTAssertEqual(bridge.connectionState.description, "disconnected")
        XCTAssertEqual(native.counts.allocations, 3)
        XCTAssertEqual(native.counts.live, 0)
        XCTAssertEqual(native.counts.duplicate, 0)
    }

    func testDisabledReconnectStillReleasesLostClient() async throws {
        var config = VNCConfiguration(); config.autoReconnect = false
        let native = FakeNative(); let clock = ManualScheduler()
        let bridge = VNCBridge(config: config, operations: native.operations, schedule: clock.schedule)
        try await bridge.connect(); clock.runNext()
        XCTAssertEqual(clock.delays, [])
        XCTAssertEqual(native.counts.releases, 1)
        XCTAssertEqual(native.counts.live, 0)
    }

    func testExplicitDisconnectCancelsBackoffAndStaleWorkCannotDestroyNewSession() async throws {
        let native = FakeNative(); let clock = ManualScheduler()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        try await bridge.connect(); clock.runNext()
        let stale = clock.take()
        XCTAssertEqual(stale.delay, 2)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        try await bridge.connect()
        stale.queue.sync { stale.work.perform() }
        XCTAssertEqual(native.counts.allocations, 2)
        XCTAssertEqual(native.counts.live, 1)
        XCTAssertEqual(native.counts.peak, 1)
        XCTAssertTrue(bridge.connectionState.isConnected)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.releases, 2)
        XCTAssertEqual(native.counts.duplicate, 0)
    }

    func testOverlappingConnectIsRefusedBeforeSecondNativeAllocation() async throws {
        let native = FakeNative(); let clock = ManualScheduler()
        let entered = expectation(description: "owned init entered")
        let release = DispatchSemaphore(value: 0)
        native.beforeInitialize = { entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        let first = Task { try await bridge.connect() }
        await fulfillment(of: [entered], timeout: 3)
        do { try await bridge.connect(); XCTFail("overlapping connect accepted") }
        catch VNCError.alreadyConnected {} catch { XCTFail("unexpected error") }
        XCTAssertEqual(native.counts.allocations, 1)
        release.signal(); try await first.value
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.releases, 1)
    }

    func testConnectCancellationWaitsForNativeOwnershipAndDoesNotReconnect() async throws {
        let native = FakeNative(); let clock = ManualScheduler()
        let entered = expectation(description: "owned init entered")
        let release = DispatchSemaphore(value: 0)
        native.beforeInitialize = { entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        let connecting = Task { try await bridge.connect() }
        await fulfillment(of: [entered], timeout: 3)
        connecting.cancel()
        XCTAssertEqual(native.counts.releases, 0) // native init still owns the pointer
        release.signal()
        do { try await connecting.value; XCTFail("cancelled connect succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected error") }
        XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(clock.delays, [])
        XCTAssertEqual(native.counts.releases, 1)
        XCTAssertEqual(native.counts.duplicate, 0)
    }

    func testDisconnectDuringNativeFailureDoesNotDoubleCleanup() async throws {
        let native = FakeNative(outcomes: [false]); let clock = ManualScheduler()
        let entered = expectation(description: "owned failing init entered")
        let release = DispatchSemaphore(value: 0)
        native.beforeInitialize = { entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        let connecting = Task { try await bridge.connect() }
        await fulfillment(of: [entered], timeout: 3)
        bridge.disconnect(); release.signal()
        do { try await connecting.value; XCTFail("disconnected connect succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected error") }
        XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.failed, 1)
        XCTAssertEqual(native.counts.releases, 1)
        XCTAssertEqual(native.counts.duplicate, 0)
        XCTAssertEqual(clock.delays, [])
    }

    func testFramebufferReadOwnsStorageUntilClosureReturns() async throws {
        let native = FakeNative(); let clock = ManualScheduler()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        try await bridge.connect()
        let entered = expectation(description: "framebuffer reader owns storage")
        let release = DispatchSemaphore(value: 0)
        let reading = Task.detached {
            bridge.withFramebuffer { buffer, width, height -> Int in
                XCTAssertEqual(width, 2); XCTAssertEqual(height, 2)
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return buffer.count
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        bridge.disconnect()
        XCTAssertEqual(native.counts.releases, 0)
        release.signal()
        let size = await reading.value
        XCTAssertEqual(size, 16)
        XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.releases, 1)
    }

    func testCallbackCanReadFramebufferAndRequestDisconnectWithoutQueueDeadlock() async throws {
        let native = FakeNative(); let clock = ManualScheduler()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        let callback = expectation(description: "connected callback reenters reader")
        bridge.onStateChange = { [weak bridge] state in
            guard state.isConnected, let bridge else { return }
            XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer.count }, 16)
            bridge.disconnect()
            callback.fulfill()
        }
        do { try await bridge.connect(); XCTFail("callback-disconnected connect succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected error") }
        await fulfillment(of: [callback], timeout: 3)
        XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.releases, 1)
        XCTAssertEqual(native.counts.duplicate, 0)
    }

    func testFailedInitializationAfterFramebufferAllocationReleasesBothOwnersOnce() async throws {
        let native = FakeNative(outcomes: [false]); native.allocateBeforeFailure = true
        let clock = ManualScheduler()
        let events = RecordedEvents()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        bridge.onStateChange = { events.append($0.isConnected ? "connected" : $0.description) }
        native.afterFramebufferAllocation = { [weak bridge] in
            XCTAssertFalse(bridge?.connectionState.isConnected ?? true)
            XCTAssertEqual(bridge?.framebufferWidth, 0)
            events.append("allocated-during-handshake")
        }
        do { try await bridge.connect(); XCTFail("failed initialization accepted") }
        catch VNCError.connectionFailed(_) {} catch { XCTFail("unexpected error") }
        XCTAssertEqual(events.values, ["connecting", "allocated-during-handshake",
                                      "error: Connection refused or handshake failed"])
        XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.failed, 1)
        XCTAssertEqual(native.counts.releases, 1)
        XCTAssertEqual(native.counts.duplicate, 0)
        XCTAssertEqual(native.bufferCounts.allocated, 1)
        XCTAssertEqual(native.bufferCounts.released, 1)
        XCTAssertEqual(native.bufferCounts.duplicate, 0)
        XCTAssertEqual(clock.delays, [])
    }

    func testConnectedEventRequiresCompletedInitialization() async throws {
        let native = FakeNative(); let clock = ManualScheduler(); let events = RecordedEvents()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        bridge.onStateChange = { events.append($0.isConnected ? "connected" : $0.description) }
        native.afterFramebufferAllocation = { [weak bridge] in
            XCTAssertFalse(bridge?.connectionState.isConnected ?? true)
            XCTAssertEqual(bridge?.framebufferWidth, 0)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            events.append("allocated-during-handshake")
        }
        try await bridge.connect()
        XCTAssertEqual(events.values, ["connecting", "allocated-during-handshake", "connected"])
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer.count }, 16)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.allocated, native.bufferCounts.released)
    }

    func testOversizedResizeRefusesBeforeAllocationOrClearingExistingBuffer() async throws {
        let native = FakeNative(polls: [true]); let clock = ManualScheduler()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        try await bridge.connect()
        native.beforePoll = { [weak native] client in
            guard let native, let original = client.pointee.frameBuffer else {
                XCTFail("expected owned initialized framebuffer"); return
            }
            let width = client.pointee.width; let height = client.pointee.height
            defer { client.pointee.width = width; client.pointee.height = height }
            let before = native.bufferCounts
            let requests = native.observedAllocationRequests
            original[0] = 0xA5
            // 512 MiB at 32 bpp: valid integer arithmetic, above the fixed cap.
            client.pointee.width = 16_384; client.pointee.height = 8192
            XCTAssertEqual(vncMallocFrameBuffer(client), 0)
            XCTAssertEqual(client.pointee.frameBuffer, original)
            XCTAssertEqual(native.observedAllocationRequests, requests)
            XCTAssertEqual(native.bufferCounts.allocated, before.allocated)
            XCTAssertEqual(native.bufferCounts.released, before.released)
            // Read only if ownership survived, so a failing guard fixture does
            // not itself dereference a buffer the candidate already released.
            if client.pointee.frameBuffer == original, native.bufferCounts.released == before.released {
                XCTAssertEqual(original[0], 0xA5)
            }
        }
        clock.runNext(); native.beforePoll = nil
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer[0] }, 0xA5)
        XCTAssertEqual(native.observedAllocationRequests, [16])
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.allocated, native.bufferCounts.released)
        XCTAssertEqual(native.bufferCounts.duplicate, 0)
    }

    func testAllocatedFramebufferCannotBeReadUntilCompleteUpdate() async throws {
        let native = FakeNative(polls: [true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let registered = expectation(description: "first-frame wait registered")
        deadline.onSchedule = { registered.fulfill() }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect()
        XCTAssertTrue(bridge.connectionState.isConnected)
        XCTAssertNil(bridge.withFramebuffer { buffer, _, _ in buffer.count })
        let events = RecordedEvents()
        let waiting = Task { try await bridge.waitForFramebuffer(); events.append("ready") }
        await fulfillment(of: [registered], timeout: 3)
        XCTAssertEqual(events.values, [])
        XCTAssertEqual(deadline.delays, [5])
        native.beforePoll = { [weak bridge] client in
            client.pointee.frameBuffer?[0] = 0x5A
            vncGotFrameBufferUpdate(client, 0, 0, 2, 2)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            vncFinishedFrameBufferUpdate(client)
        }
        clock.runNext(); try await waiting.value
        XCTAssertEqual(events.values, ["ready"])
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer[0] }, 0x5A)
        deadline.runNext() // stale timeout must not resume the continuation twice
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.live, 0)
    }

    func testCompletedBlackFrameIsValidWithoutPixelColorHeuristic() async throws {
        let native = FakeNative(polls: [true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect()
        XCTAssertNil(bridge.withFramebuffer { buffer, _, _ in buffer.count })
        native.beforePoll = { client in
            memset(client.pointee.frameBuffer, 0, 16) // real decoded black pixels
            completePixelUpdate(client)
        }
        clock.runNext()
        try await bridge.waitForFramebuffer()
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer.allSatisfy { $0 == 0 } }, true)
        XCTAssertEqual(deadline.delays, [])
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
    }

    func testEmptyOrMetadataOnlyCompletionDoesNotAdmitUntouchedPixels() async throws {
        let native = FakeNative(polls: [true, true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let registered = expectation(description: "reader waits through metadata-only messages")
        deadline.onSchedule = { registered.fulfill() }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect()
        let events = RecordedEvents()
        let waiting = Task { try await bridge.waitForFramebuffer(); events.append("ready") }
        await fulfillment(of: [registered], timeout: 3)
        native.beforePoll = { [weak bridge] client in
            // 0.9.15 sends only Finished for empty and cursor pseudo-rectangles.
            vncFinishedFrameBufferUpdate(client)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            let invalidRectangles: [(Int32, Int32, Int32, Int32)] =
                [(0, 0, 0, 2), (0, 0, 2, 0), (-1, 0, 1, 1), (0, -1, 1, 1),
                 (1, 0, 2, 2), (0, 1, 2, 2), (0, 0, .max, .max)]
            for (x, y, width, height) in invalidRectangles {
                vncGotFrameBufferUpdate(client, x, y, width, height)
                vncFinishedFrameBufferUpdate(client)
                XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            }
        }
        clock.runNext()
        XCTAssertEqual(events.values, [])
        XCTAssertEqual(deadline.delays, [5]) // metadata never renews the deadline
        native.beforePoll = { completePixelUpdate($0) }
        clock.runNext(); try await waiting.value
        deadline.runNext()
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
    }

    func testFirstFrameDeadlineCompletesWhileNativeReadIsOccupied() async throws {
        let native = FakeNative(polls: [true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let registered = expectation(description: "first-frame deadline registered")
        deadline.onSchedule = { registered.fulfill() }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect()
        let waiting = Task { try await bridge.waitForFramebuffer() }
        await fulfillment(of: [registered], timeout: 3)
        let entered = expectation(description: "owned native read occupied")
        let release = DispatchSemaphore(value: 0)
        native.beforePoll = { _ in
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let polling = Task.detached { clock.runNext() }
        await fulfillment(of: [entered], timeout: 3)
        deadline.runNext()
        do { try await waiting.value; XCTFail("missing update accepted") }
        catch VNCError.sendFailed(let reason) {
            XCTAssertEqual(reason, "No complete framebuffer update within 5 seconds")
        } catch { XCTFail("unexpected error") }
        release.signal(); await polling.value
        XCTAssertNil(bridge.withFramebuffer { buffer, _, _ in buffer.count })
        // A timeout neither invents a frame nor disables a later real update.
        native.beforePoll = { completePixelUpdate($0) }
        clock.runNext(); try await bridge.waitForFramebuffer()
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
    }

    func testCancellingOneFrameWaitDoesNotCancelAnotherReader() async throws {
        let native = FakeNative(polls: [true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let registered = expectation(description: "two independent readers registered")
        registered.expectedFulfillmentCount = 2
        deadline.onSchedule = { registered.fulfill() }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect()
        let cancelled = Task { try await bridge.waitForFramebuffer() }
        let remaining = Task { try await bridge.waitForFramebuffer() }
        await fulfillment(of: [registered], timeout: 3)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("cancelled reader accepted") }
        catch is CancellationError {} catch { XCTFail("unexpected error") }
        native.beforePoll = { completePixelUpdate($0) }
        clock.runNext(); try await remaining.value
        deadline.runNext(); deadline.runNext()
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer.count }, 16)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
    }

    func testAlreadyCancelledFrameWaitCannotRegisterOrSucceed() async throws {
        let native = FakeNative(); let clock = ManualScheduler(); let deadline = ManualScheduler()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await bridge.waitForFramebuffer()
        }
        do { try await cancelled.value; XCTFail("already-cancelled reader accepted") }
        catch is CancellationError {} catch { XCTFail("unexpected error") }
        XCTAssertEqual(deadline.delays, [])
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
    }

    func testDisconnectRefusesPendingFirstFrameAndReleasesOwnership() async throws {
        let native = FakeNative(); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let registered = expectation(description: "reader registered before disconnect")
        deadline.onSchedule = { registered.fulfill() }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect()
        let waiting = Task { try await bridge.waitForFramebuffer() }
        await fulfillment(of: [registered], timeout: 3)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        do { try await waiting.value; XCTFail("disconnected reader accepted") }
        catch VNCError.notConnected {} catch { XCTFail("unexpected error") }
        deadline.runNext()
        XCTAssertNil(bridge.withFramebuffer { buffer, _, _ in buffer.count })
        XCTAssertEqual(native.counts.live, 0)
        XCTAssertEqual(native.bufferCounts.live, 0)
        XCTAssertEqual(native.bufferCounts.duplicate, 0)
    }

    func testReconnectRequiresItsOwnCompletedFramebufferUpdate() async throws {
        let native = FakeNative(polls: [false, true])
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let registered = expectation(description: "new connection waits for its own frame")
        deadline.onSchedule = { registered.fulfill() }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect(); try await bridge.waitForFramebuffer()
        native.completeDuringInitialize = false
        clock.runNext() // loss of the previously complete frame
        do { try await bridge.waitForFramebuffer(); XCTFail("lost connection accepted") }
        catch VNCError.notConnected {} catch { XCTFail("unexpected error") }
        clock.runNext() // successful reconnect, only allocated so far
        XCTAssertTrue(bridge.connectionState.isConnected)
        XCTAssertNil(bridge.withFramebuffer { buffer, _, _ in buffer.count })
        let waiting = Task { try await bridge.waitForFramebuffer() }
        await fulfillment(of: [registered], timeout: 3)
        native.beforePoll = { completePixelUpdate($0) }
        clock.runNext(); try await waiting.value
        deadline.runNext()
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.peak, 1)
        XCTAssertEqual(native.bufferCounts.allocated, native.bufferCounts.released)
    }

    func testResizeInvalidatesReadinessUntilNewSizeCompletes() async throws {
        let native = FakeNative(polls: [true, true])
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let registered = expectation(description: "resized buffer waits for complete update")
        deadline.onSchedule = { registered.fulfill() }
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect(); try await bridge.waitForFramebuffer()
        native.beforePoll = { client in
            client.pointee.width = 3; client.pointee.height = 3
            XCTAssertNotEqual(vncMallocFrameBuffer(client), 0)
        }
        clock.runNext()
        XCTAssertNil(bridge.withFramebuffer { buffer, _, _ in buffer.count })
        let waiting = Task { try await bridge.waitForFramebuffer() }
        await fulfillment(of: [registered], timeout: 3)
        native.beforePoll = { completePixelUpdate($0) }
        clock.runNext(); try await waiting.value
        XCTAssertEqual(bridge.withFramebuffer { buffer, width, height in
            XCTAssertEqual(width, 3); XCTAssertEqual(height, 3)
            return buffer.count
        }, 36)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.allocated, 2)
        XCTAssertEqual(native.bufferCounts.released, 2)
        XCTAssertEqual(native.bufferCounts.duplicate, 0)
    }

    func testNativeTimeoutAndRetryDelayBoundsAreAppliedToActualOperations() async throws {
        var config = VNCConfiguration(); config.connectTimeout = 1000; config.reconnectDelay = .infinity
        config.messageLoopInterval = .max
        let native = FakeNative(); let clock = ManualScheduler()
        let bridge = VNCBridge(config: config, operations: native.operations, schedule: clock.schedule)
        try await bridge.connect()
        XCTAssertEqual(native.observedTimeouts[0].0, 30)
        XCTAssertEqual(native.observedTimeouts[0].1, 30)
        clock.runNext(); XCTAssertEqual(clock.delays, [2])
        XCTAssertEqual(native.observedPollIntervals, [250_000])
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.counts.live, 0)
    }
}
