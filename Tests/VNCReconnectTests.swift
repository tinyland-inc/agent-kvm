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
        poll: { [self] client, interval, phase in
            phase(.handlingServerMessage)
            beforePoll?(client)
            phase(.idle)
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
    private func timeoutDiagnostics(_ reason: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let prefix = "No complete framebuffer update within 5 seconds; diagnostics="
        XCTAssertTrue(reason.hasPrefix(prefix), file: file, line: line)
        let payload = String(reason.dropFirst(prefix.count))
        XCTAssertLessThanOrEqual(payload.utf8.count, 1024, file: file, line: line)
        let data = Data(payload.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   file: file, line: line)
        let required: Set<String> = [
            "connection_generation", "allocations", "width", "height", "pixels_remaining",
            "rectangles", "copy_rectangles", "finished_updates", "rejected_rectangles",
            "skipped_copy_rectangles", "complete", "phase"
        ]
        let keys = Set(object.keys)
        XCTAssertTrue(required.isSubset(of: keys), file: file, line: line)
        XCTAssertTrue(keys.isSubset(of: required.union(["last_callback_age_milliseconds"])),
                      file: file, line: line)
        for key in required.subtracting(["complete", "phase"]) {
            XCTAssertNotNil(object[key] as? Int, "non-numeric diagnostic: \(key)", file: file, line: line)
        }
        XCTAssertNotNil(object["complete"] as? Bool, file: file, line: line)
        let phases: Set<String> = ["initializing", "idle", "waitingForMessage",
                                   "handlingServerMessage", "requestingIncrementalUpdate", "disconnected"]
        XCTAssertTrue(phases.contains(object["phase"] as? String ?? ""), file: file, line: line)
        if let age = object["last_callback_age_milliseconds"], !(age is NSNull) {
            XCTAssertNotNil(age as? UInt64, file: file, line: line)
        }
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data,
                       "diagnostics must be compact, sorted JSON", file: file, line: line)
        return object
    }

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

    func testPartialInitialUpdatesOverlapAndHolesCannotAdmitOrRenewDeadline() async throws {
        let native = FakeNative(polls: [true, true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let deadline = ManualScheduler()
        let registered = expectation(description: "partial initial screen retains original deadline")
        deadline.onSchedule = { registered.fulfill() }
        var config = VNCConfiguration()
        config.host = "fixture-private-host.invalid"
        config.username = "fixture-private-user"
        config.password = "fixture-private-password"
        let bridge = VNCBridge(config: config, operations: native.operations, schedule: clock.schedule,
                               scheduleFrameDeadline: deadline.schedule)
        try await bridge.connect()
        let waiting = Task { try await bridge.waitForFramebuffer() }
        await fulfillment(of: [registered], timeout: 3)
        native.beforePoll = { [weak bridge] client in
            // Neither pixels nor configured connection secrets belong in a
            // coverage/control-flow diagnostic.
            _ = Array("PIXEL_PRIVATE".utf8).withUnsafeBytes { bytes in
                memcpy(client.pointee.frameBuffer!, bytes.baseAddress!, bytes.count)
            }
            // Summed area exceeds the screen; the bottom-right pixel is still
            // absent. Completion of each message cannot bless that hole.
            let rectangles: [(Int32, Int32, Int32, Int32)] =
                [(0, 0, 2, 1), (0, 0, 2, 1), (0, 0, 1, 2)]
            for (x, y, w, h) in rectangles {
                vncGotFrameBufferUpdate(client, x, y, w, h)
                vncFinishedFrameBufferUpdate(client)
                XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            }
        }
        clock.runNext()
        let partial = bridge.framebufferDiagnostics
        XCTAssertEqual(partial.connectionGeneration, 1)
        XCTAssertEqual(partial.allocations, 1)
        XCTAssertEqual(partial.width, 2)
        XCTAssertEqual(partial.height, 2)
        XCTAssertEqual(partial.pixelsRemaining, 1)
        XCTAssertEqual(partial.rectangles, 3)
        XCTAssertEqual(partial.finishedUpdates, 3)
        XCTAssertEqual(partial.copyRectangles, 0)
        XCTAssertEqual(partial.rejectedRectangles, 0)
        XCTAssertEqual(partial.skippedCopyRectangles, 0)
        XCTAssertFalse(partial.complete)
        XCTAssertNotNil(partial.lastCallbackAgeMilliseconds)
        XCTAssertEqual(deadline.delays, [5])
        deadline.runNext()
        do { try await waiting.value; XCTFail("partial screen admitted") }
        catch VNCError.sendFailed(let reason) {
            let diagnostic = try timeoutDiagnostics(reason)
            XCTAssertEqual(diagnostic["pixels_remaining"] as? Int, 1)
            XCTAssertEqual(diagnostic["rectangles"] as? Int, 3)
            XCTAssertEqual(diagnostic["finished_updates"] as? Int, 3)
            XCTAssertEqual(diagnostic["complete"] as? Bool, false)
            for privateValue in [config.host, config.username!, config.password!, "PIXEL_PRIVATE"] {
                XCTAssertFalse(reason.contains(privateValue))
            }
        } catch { XCTFail("unexpected error") }
        native.beforePoll = { [weak bridge] client in
            vncGotFrameBufferUpdate(client, 1, 1, 1, 1)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            vncFinishedFrameBufferUpdate(client)
        }
        clock.runNext(); try await bridge.waitForFramebuffer()
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer.count }, 16)
        XCTAssertEqual(bridge.framebufferDiagnostics.pixelsRemaining, 0)
        XCTAssertTrue(bridge.framebufferDiagnostics.complete)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.live, 0)
    }

    func testCoverageAcrossWordAndRowBoundariesRequiresLastPixel() async throws {
        let native = FakeNative(polls: [true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let bridge = VNCBridge(operations: native.operations,
                                                              schedule: clock.schedule)
        try await bridge.connect()
        native.beforePoll = { [weak bridge] client in
            client.pointee.width = 67; client.pointee.height = 2
            XCTAssertNotEqual(vncMallocFrameBuffer(client), 0)
            // A 67-pixel stride exercises both word boundaries and a partial
            // final word. Duplicate top-right coverage cannot fill bottom-right.
            let rectangles: [(Int32, Int32, Int32, Int32)] =
                [(0, 0, 64, 2), (64, 0, 3, 1), (64, 0, 3, 1), (64, 1, 2, 1)]
            for (x, y, w, h) in rectangles {
                vncGotFrameBufferUpdate(client, x, y, w, h)
                vncFinishedFrameBufferUpdate(client)
                XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            }
            vncGotFrameBufferUpdate(client, 66, 1, 1, 1)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            vncFinishedFrameBufferUpdate(client)
        }
        clock.runNext(); try await bridge.waitForFramebuffer()
        XCTAssertEqual(bridge.withFramebuffer { buffer, width, height in
            XCTAssertEqual(width, 67); XCTAssertEqual(height, 2); return buffer.count
        }, 536)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.allocated, native.bufferCounts.released)
    }

    func testResizeDiscardsPartialCoverageEvenWhenDimensionsStayEqual() async throws {
        let native = FakeNative(polls: [true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let bridge = VNCBridge(operations: native.operations,
                                                              schedule: clock.schedule)
        try await bridge.connect()
        let generation = bridge.framebufferDiagnostics.connectionGeneration
        native.beforePoll = { [weak bridge] client in
            vncGotFrameBufferUpdate(client, 0, 0, 2, 1)
            vncFinishedFrameBufferUpdate(client)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            XCTAssertNotEqual(vncMallocFrameBuffer(client), 0)
            if let diagnostic = bridge?.framebufferDiagnostics {
                XCTAssertEqual(diagnostic.connectionGeneration, generation)
                XCTAssertEqual(diagnostic.allocations, 2)
                XCTAssertEqual(diagnostic.pixelsRemaining, 4)
                XCTAssertEqual(diagnostic.rectangles, 0)
                XCTAssertEqual(diagnostic.finishedUpdates, 0)
                XCTAssertFalse(diagnostic.complete)
            }
            vncGotFrameBufferUpdate(client, 0, 1, 2, 1)
            vncFinishedFrameBufferUpdate(client)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            vncGotFrameBufferUpdate(client, 0, 0, 2, 1)
            vncFinishedFrameBufferUpdate(client)
        }
        clock.runNext(); try await bridge.waitForFramebuffer()
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer.count }, 16)
        XCTAssertEqual(bridge.framebufferDiagnostics.rectangles, 2)
        XCTAssertEqual(bridge.framebufferDiagnostics.finishedUpdates, 2)
        XCTAssertEqual(bridge.framebufferDiagnostics.pixelsRemaining, 0)
        XCTAssertTrue(bridge.framebufferDiagnostics.complete)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.allocated, 2)
        XCTAssertEqual(native.bufferCounts.released, 2)
    }

    func testInitializedFramebufferStillAcceptsSmallIncrementalUpdates() async throws {
        let native = FakeNative(polls: [true]); let clock = ManualScheduler()
        let bridge = VNCBridge(operations: native.operations, schedule: clock.schedule)
        try await bridge.connect(); try await bridge.waitForFramebuffer()
        native.beforePoll = { client in
            client.pointee.frameBuffer?[12] = 0x7F
            vncGotFrameBufferUpdate(client, 1, 1, 1, 1)
            vncFinishedFrameBufferUpdate(client)
        }
        clock.runNext(); try await bridge.waitForFramebuffer()
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer[12] }, 0x7F)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.live, 0)
    }

    func testCopyRectPropagatesUnknownAndReceivedPixelsWithoutInventingCoverage() async throws {
        let native = FakeNative(polls: [true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let bridge = VNCBridge(operations: native.operations,
                                                              schedule: clock.schedule)
        try await bridge.connect()
        native.beforePoll = { [weak bridge] client in
            client.pointee.frameBuffer?[0] = 0x6A
            vncGotFrameBufferUpdate(client, 0, 0, 2, 1)
            vncFinishedFrameBufferUpdate(client)
            // Copy unreceived bottom pixels over the received top row. The
            // subsequent generic callback must not mark that row as received.
            vncGotCopyRect(client, 0, 1, 2, 1, 0, 0)
            vncGotFrameBufferUpdate(client, 0, 0, 2, 1)
            vncFinishedFrameBufferUpdate(client)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            client.pointee.frameBuffer?[8] = 0x4B
            vncGotFrameBufferUpdate(client, 0, 1, 2, 1)
            vncFinishedFrameBufferUpdate(client)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            vncGotCopyRect(client, 0, 1, 2, 1, 0, 0)
            vncGotFrameBufferUpdate(client, 0, 0, 2, 1)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            vncFinishedFrameBufferUpdate(client)
        }
        clock.runNext(); try await bridge.waitForFramebuffer()
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer[0] }, 0x4B)
        XCTAssertEqual(bridge.framebufferDiagnostics.copyRectangles, 2)
        XCTAssertEqual(bridge.framebufferDiagnostics.skippedCopyRectangles, 2)
        XCTAssertEqual(bridge.framebufferDiagnostics.rectangles, 4)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.live, 0)
    }

    func testOverlappingCopyRectCannotSpreadOneKnownPixelAcrossUnknownSource() async throws {
        let native = FakeNative(polls: [true]); native.completeDuringInitialize = false
        let clock = ManualScheduler(); let bridge = VNCBridge(operations: native.operations,
                                                              schedule: clock.schedule)
        try await bridge.connect()
        native.beforePoll = { [weak bridge] client in
            client.pointee.width = 4; client.pointee.height = 1
            XCTAssertNotEqual(vncMallocFrameBuffer(client), 0)
            vncGotFrameBufferUpdate(client, 0, 0, 1, 1)
            vncFinishedFrameBufferUpdate(client)
            // memmove order: only positions 0 and 1 can become valid. A
            // left-to-right validity copy would incorrectly fill all four.
            vncGotCopyRect(client, 0, 0, 3, 1, 1, 0)
            vncGotFrameBufferUpdate(client, 1, 0, 3, 1)
            vncFinishedFrameBufferUpdate(client)
            XCTAssertNil(bridge?.withFramebuffer { buffer, _, _ in buffer.count })
            vncGotFrameBufferUpdate(client, 2, 0, 2, 1)
            vncFinishedFrameBufferUpdate(client)
        }
        clock.runNext(); try await bridge.waitForFramebuffer()
        XCTAssertEqual(bridge.withFramebuffer { buffer, _, _ in buffer.count }, 16)
        bridge.disconnect(); XCTAssertEqual(bridge.framebufferWidth, 0)
        XCTAssertEqual(native.bufferCounts.allocated, native.bufferCounts.released)
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
        XCTAssertEqual(bridge.framebufferDiagnostics.rejectedRectangles, 7)
        XCTAssertEqual(bridge.framebufferDiagnostics.rectangles, 7)
        XCTAssertEqual(bridge.framebufferDiagnostics.finishedUpdates, 8)
        XCTAssertEqual(bridge.framebufferDiagnostics.pixelsRemaining, 4)
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
        let snapshotFinished = expectation(description: "diagnostic snapshot bypasses occupied native queue")
        let snapshot = Task.detached {
            let value = bridge.framebufferDiagnostics
            snapshotFinished.fulfill()
            return value
        }
        let timeoutFinished = expectation(description: "diagnostic timeout bypasses occupied native queue")
        let timeout = Task { () -> String? in
            defer { timeoutFinished.fulfill() }
            do { try await waiting.value; XCTFail("missing update accepted") }
            catch VNCError.sendFailed(let reason) { return reason }
            catch { XCTFail("unexpected error") }
            return nil
        }
        let firing = Task.detached { deadline.runNext() }
        // A regression may fail these expectations, but releasing the owned
        // barrier still lets all test tasks unwind instead of hanging XCTest.
        await fulfillment(of: [snapshotFinished, timeoutFinished], timeout: 2)
        release.signal(); await polling.value
        await firing.value
        let occupied = await snapshot.value
        XCTAssertEqual(occupied.phase, .handlingServerMessage)
        XCTAssertEqual(occupied.allocations, 1)
        XCTAssertEqual(occupied.pixelsRemaining, 4)
        XCTAssertEqual(occupied.rectangles, 0)
        XCTAssertEqual(occupied.finishedUpdates, 0)
        XCTAssertFalse(occupied.complete)
        let reason = await timeout.value
        let diagnostic = try timeoutDiagnostics(try XCTUnwrap(reason))
        XCTAssertEqual(diagnostic["phase"] as? String, "handlingServerMessage")
        XCTAssertEqual(diagnostic["pixels_remaining"] as? Int, 4)
        XCTAssertEqual(diagnostic["rectangles"] as? Int, 0)
        XCTAssertEqual(diagnostic["finished_updates"] as? Int, 0)
        XCTAssertEqual(diagnostic["complete"] as? Bool, false)
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
        let original = bridge.framebufferDiagnostics
        XCTAssertTrue(original.complete)
        XCTAssertEqual(original.rectangles, 1)
        native.completeDuringInitialize = false
        clock.runNext() // loss of the previously complete frame
        do { try await bridge.waitForFramebuffer(); XCTFail("lost connection accepted") }
        catch VNCError.notConnected {} catch { XCTFail("unexpected error") }
        clock.runNext() // successful reconnect, only allocated so far
        XCTAssertTrue(bridge.connectionState.isConnected)
        XCTAssertNil(bridge.withFramebuffer { buffer, _, _ in buffer.count })
        let reconnected = bridge.framebufferDiagnostics
        XCTAssertEqual(reconnected.connectionGeneration, original.connectionGeneration + 1)
        XCTAssertEqual(reconnected.allocations, 1)
        XCTAssertEqual(reconnected.width, 2)
        XCTAssertEqual(reconnected.height, 2)
        XCTAssertEqual(reconnected.pixelsRemaining, 4)
        XCTAssertEqual(reconnected.rectangles, 0)
        XCTAssertEqual(reconnected.copyRectangles, 0)
        XCTAssertEqual(reconnected.finishedUpdates, 0)
        XCTAssertEqual(reconnected.rejectedRectangles, 0)
        XCTAssertEqual(reconnected.skippedCopyRectangles, 0)
        XCTAssertFalse(reconnected.complete)
        let waiting = Task { try await bridge.waitForFramebuffer() }
        await fulfillment(of: [registered], timeout: 3)
        native.beforePoll = { completePixelUpdate($0) }
        clock.runNext(); try await waiting.value
        XCTAssertEqual(bridge.framebufferDiagnostics.connectionGeneration, reconnected.connectionGeneration)
        XCTAssertEqual(bridge.framebufferDiagnostics.rectangles, 1)
        XCTAssertEqual(bridge.framebufferDiagnostics.finishedUpdates, 1)
        XCTAssertEqual(bridge.framebufferDiagnostics.pixelsRemaining, 0)
        XCTAssertTrue(bridge.framebufferDiagnostics.complete)
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
        let resized = bridge.framebufferDiagnostics
        XCTAssertEqual(resized.allocations, 2)
        XCTAssertEqual(resized.width, 3)
        XCTAssertEqual(resized.height, 3)
        XCTAssertEqual(resized.pixelsRemaining, 9)
        XCTAssertEqual(resized.rectangles, 0)
        XCTAssertEqual(resized.finishedUpdates, 0)
        XCTAssertFalse(resized.complete)
        let waiting = Task { try await bridge.waitForFramebuffer() }
        await fulfillment(of: [registered], timeout: 3)
        native.beforePoll = { completePixelUpdate($0) }
        clock.runNext(); try await waiting.value
        XCTAssertEqual(bridge.withFramebuffer { buffer, width, height in
            XCTAssertEqual(width, 3); XCTAssertEqual(height, 3)
            return buffer.count
        }, 36)
        // The owned allocator refuses this 1156-byte request before malloc.
        // Diagnostics must describe the failed new attempt, not the old frame.
        native.beforePoll = { client in
            client.pointee.width = 17; client.pointee.height = 17
            XCTAssertEqual(vncMallocFrameBuffer(client), 0)
        }
        clock.runNext()
        let refused = bridge.framebufferDiagnostics
        XCTAssertEqual(refused.allocations, 3)
        XCTAssertEqual(refused.width, 17)
        XCTAssertEqual(refused.height, 17)
        XCTAssertEqual(refused.pixelsRemaining, 289)
        XCTAssertEqual(refused.rectangles, 0)
        XCTAssertEqual(refused.copyRectangles, 0)
        XCTAssertEqual(refused.finishedUpdates, 0)
        XCTAssertEqual(refused.rejectedRectangles, 0)
        XCTAssertEqual(refused.skippedCopyRectangles, 0)
        XCTAssertFalse(refused.complete)
        XCTAssertNil(bridge.withFramebuffer { buffer, _, _ in buffer.count })
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
