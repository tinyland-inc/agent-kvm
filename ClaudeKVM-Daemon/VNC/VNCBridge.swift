import Foundation
import os
import CLibVNCClient

/// Swift bridge over LibVNCClient (C). Manages a persistent VNC connection
/// with queue-scoped zero-copy framebuffer readers.
final class VNCBridge: @unchecked Sendable {

    /// Fixed allocation ceiling: 256 MiB accommodates an 8K 32-bit desktop
    /// (7680 × 4320 × 4 bytes) without trusting server dimensions as a budget.
    static let maximumFramebufferBytes = 256 * 1024 * 1024

    // MARK: Public Properties

    var verbose = false
    /// Whether the VNC server is macOS Apple VNC (detected from RFB version 003.889 or --macos flag)
    var isMacOS: Bool = false
    var onStateChange: ((VNCConnectionState) -> Void)?

    // MARK: Internal Properties (accessed by VNCCallbacks)

    let config: VNCConfiguration
    private let frameStreamStorage = OSAllocatedUnfairLock<AsyncStream<Void>.Continuation?>(initialState: nil)
    var framebufferUpdateContinuation: AsyncStream<Void>.Continuation? {
        get { frameStreamStorage.withLock { $0 } }
        set { frameStreamStorage.withLock { $0 = newValue } }
    }

    // MARK: Private Properties

    private var client: UnsafeMutablePointer<rfbClient>?
    // Buffer allocation can precede a failed native handshake. Only a successful
    // initialize call makes the client available to readers, input and observers.
    private var clientReady = false
    private var framebufferReceivedPixels = false
    private var framebufferHasUpdate = false
    private var ownedFramebuffer: UnsafeMutablePointer<UInt8>?
    private final class FrameWaiter {
        let id = UUID()
        var continuation: CheckedContinuation<Void, Error>?
        var cancelled = false
        var deadline: DispatchWorkItem?
    }
    private struct FrameReadiness {
        var available = false
        var complete = false
        var waiters: [UUID: FrameWaiter] = [:]
    }
    private let frameReadiness = OSAllocatedUnfairLock(initialState: FrameReadiness())
    private let stateStorage = OSAllocatedUnfairLock(initialState: VNCConnectionState.disconnected)
    // Desired connection identity is independently cancellable while a bounded
    // native call occupies the queue. Every C client access belongs to the queue.
    private let desiredSession = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    private var clientSession: UUID?
    private var pendingWork: DispatchWorkItem?
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let operations: VNCClientOperations
    private let schedule: VNCWorkScheduler
    private let scheduleFrameDeadline: VNCWorkScheduler
    private let messageQueue = DispatchQueue(label: "vnc.message-loop", qos: .userInteractive)
    /// Only touched on messageQueue (message loop).
    private var lastUpdateRequestNs: UInt64 = 0
    private var reconnectCount = 0
    private let stateStreamStorage = OSAllocatedUnfairLock<AsyncStream<VNCConnectionState>.Continuation?>(initialState: nil)
    private var stateStreamContinuation: AsyncStream<VNCConnectionState>.Continuation? {
        get { stateStreamStorage.withLock { $0 } }
        set { stateStreamStorage.withLock { $0 = newValue } }
    }

    // MARK: Init / Deinit

    init(config: VNCConfiguration = .init(),
         operations: VNCClientOperations = .native,
         schedule: @escaping VNCWorkScheduler = scheduleVNCWork,
         scheduleFrameDeadline: @escaping VNCWorkScheduler = scheduleVNCWork) {
        self.config = config
        self.operations = operations
        self.schedule = schedule
        self.scheduleFrameDeadline = scheduleFrameDeadline
        messageQueue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        // A queued native call retains self until it returns; scheduled work
        // uses weak captures. Deinit can therefore only free an idle client.
        onMessageQueue {
            pendingWork?.cancel()
            cleanupClient()
        }
    }

    private func onMessageQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return messageQueue.sync(execute: body)
    }

    private func wants(_ session: UUID) -> Bool {
        desiredSession.withLock { $0 == session }
    }

    private var activeClient: UnsafeMutablePointer<rfbClient>? {
        guard clientReady, let session = clientSession, wants(session) else { return nil }
        return client
    }

    private func releaseFramebuffer() {
        framebufferReceivedPixels = false
        framebufferHasUpdate = false
        if let buffer = ownedFramebuffer {
            ownedFramebuffer = nil
            operations.freeFramebuffer(buffer)
        }
    }

    private func cleanupClient() {
        clientReady = false
        publishFrameReadiness(available: false, complete: false)
        if let owned = client {
            client = nil
            owned.pointee.frameBuffer = nil
            releaseFramebuffer()
            operations.cleanup(owned)
        } else {
            releaseFramebuffer()
        }
    }

    /// Only invoked synchronously by the C allocation callback on messageQueue.
    func allocateFramebuffer(for native: UnsafeMutablePointer<rfbClient>) -> rfbBool {
        guard DispatchQueue.getSpecific(key: queueKey) != nil, client == native else { return 0 }
        let width = Int(native.pointee.width)
        let height = Int(native.pointee.height)
        let bpp = Int(native.pointee.format.bitsPerPixel) / 8
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (size, byteOverflow) = pixels.multipliedReportingOverflow(by: bpp)
        // Refuse before freeing/clearing the current buffer or invoking an
        // allocator. Checked arithmetic alone is not a finite resource bound.
        guard width > 0, height > 0, bpp > 0, !pixelOverflow, !byteOverflow,
              size <= Self.maximumFramebufferBytes else { return 0 }
        native.pointee.frameBuffer = nil
        releaseFramebuffer()
        publishFrameReadiness(available: activeClient != nil, complete: false)
        guard let buffer = operations.allocateFramebuffer(size) else { return 0 }
        memset(buffer, 0, size)
        ownedFramebuffer = buffer
        native.pointee.frameBuffer = buffer
        if clientReady { updateState(.connected(width: width, height: height)) }
        return -1
    }

    /// LibVNCClient skips this rectangle callback for cursor/size pseudo-encodings.
    /// Never inspect pixel color: an actually received black rectangle is valid.
    func receivedFramebufferRectangle(for native: UnsafeMutablePointer<rfbClient>,
                                      x: Int32, y: Int32, width: Int32, height: Int32) {
        guard DispatchQueue.getSpecific(key: queueKey) != nil, client == native,
              native.pointee.frameBuffer != nil,
              let session = clientSession, wants(session),
              x >= 0, y >= 0, width > 0, height > 0,
              Int64(x) + Int64(width) <= Int64(native.pointee.width),
              Int64(y) + Int64(height) <= Int64(native.pointee.height) else { return }
        framebufferReceivedPixels = true
    }

    /// Completion alone also fires for empty or cursor-only messages. Require
    /// both received pixels for this allocation and a fully processed message.
    func finishedFramebufferUpdate(for native: UnsafeMutablePointer<rfbClient>) {
        guard DispatchQueue.getSpecific(key: queueKey) != nil, client == native,
              native.pointee.frameBuffer != nil, framebufferReceivedPixels,
              let session = clientSession, wants(session) else { return }
        framebufferHasUpdate = true
        if clientReady { publishFrameReadiness(available: true, complete: true) }
        framebufferUpdateContinuation?.yield(())
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        let session = UUID()
        guard desiredSession.withLock({ desired in
            guard desired == nil else { return false }
            desired = session
            return true
        }) else { throw VNCError.alreadyConnected }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                messageQueue.async { [self] in
                    guard wants(session) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pendingWork?.cancel()
                    pendingWork = nil
                    cleanupClient()
                    clientSession = session
                    reconnectCount = 0
                    do {
                        try attemptConnection(session)
                        continuation.resume()
                    } catch {
                        if wants(session) {
                            desiredSession.withLock { if $0 == session { $0 = nil } }
                            updateState(.error("Connection refused or handshake failed"))
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancel(session)
        }
    }

    func disconnect() {
        let session = desiredSession.withLock { desired -> UUID? in
            let old = desired
            desired = nil
            return old
        }
        guard let session else { return }
        enqueueCleanup(session)
    }

    private func cancel(_ session: UUID) {
        desiredSession.withLock { if $0 == session { $0 = nil } }
        enqueueCleanup(session)
    }

    private func enqueueCleanup(_ session: UUID) {
        // Never free from a C callback, nor concurrently with native handshake,
        // message handling, input or a framebuffer reader. A stale cancellation
        // cannot clear a later session or destroy its client.
        messageQueue.async { [weak self] in
            guard let self, self.clientSession == session else { return }
            self.pendingWork?.cancel()
            self.pendingWork = nil
            self.cleanupClient()
            self.clientSession = nil
            if self.desiredSession.withLock({ $0 == nil }) {
                self.updateState(.disconnected)
            }
        }
    }

    private func attemptConnection(_ session: UUID) throws {
        guard wants(session) else { throw CancellationError() }
        updateState(.connecting)
        guard wants(session) else { throw CancellationError() }
        guard let newClient = operations.make(config) else {
            throw VNCError.connectionFailed("rfbGetClient returned nil")
        }
        client = newClient
        clientReady = false
        newClient.pointee.serverPort = Int32(config.port)
        newClient.pointee.serverHost = strdup(config.host)
        rfbClientSetClientData(newClient, &vncBridgeTag,
                              Unmanaged.passUnretained(self).toOpaque())
        newClient.pointee.MallocFrameBuffer = vncMallocFrameBuffer
        newClient.pointee.GotFrameBufferUpdate = vncGotFrameBufferUpdate
        newClient.pointee.FinishedFrameBufferUpdate = vncFinishedFrameBufferUpdate
        newClient.pointee.GetPassword = vncGetPassword
        newClient.pointee.GetCredential = vncGetCredential
        newClient.pointee.GotXCutText = vncGotXCutText
        // A zero upstream default meant unbounded connect/read waits. These
        // are native per-operation limits, not a whole-handshake deadline.
        let timeout = config.connectTimeout > 0 ? min(config.connectTimeout, 30) : 10
        newClient.pointee.connectTimeout = UInt32(timeout)
        newClient.pointee.readTimeout = UInt32(timeout)
        // On failure LibVNCClient consumes the client. Do not clean it twice.
        guard operations.initialize(newClient) else {
            client = nil // the C pointer has already been consumed
            releaseFramebuffer()
            if !wants(session) { throw CancellationError() }
            throw VNCError.connectionFailed("Connection refused or handshake failed")
        }
        guard wants(session) else {
            cleanupClient()
            throw CancellationError()
        }
        clientReady = true
        publishFrameReadiness(available: true, complete: framebufferHasUpdate)
        updateState(.connected(width: Int(newClient.pointee.width), height: Int(newClient.pointee.height)))
        // A connected callback may request disconnect; never schedule work or
        // report connect success after that callback cancels this generation.
        guard wants(session) else {
            cleanupClient()
            throw CancellationError()
        }
        reconnectCount = 0
        lastUpdateRequestNs = 0
        enqueuePoll(session)
    }

    // MARK: - State

    var connectionState: VNCConnectionState {
        stateStorage.withLock { $0 }
    }

    func stateStream() -> AsyncStream<VNCConnectionState> {
        AsyncStream { continuation in
            self.stateStreamContinuation = continuation
            continuation.yield(self.connectionState)
            continuation.onTermination = { @Sendable _ in
                self.stateStreamContinuation = nil
            }
        }
    }

    func updateState(_ newState: VNCConnectionState) {
        if newState.isConnected {
            guard clientReady, let session = clientSession, wants(session) else { return }
        }
        stateStorage.withLock { $0 = newState }
        onStateChange?(newState)
        stateStreamContinuation?.yield(newState)
        log("State: \(newState)")
    }

    // MARK: - Framebuffer Access (Zero-Copy)

    // Callers complete framebuffer reads inside this queued closure. The queue
    // also owns resize callbacks and cleanup; the raw-pointer property is removed.
    var framebufferWidth: Int { onMessageQueue { activeClient.map { Int($0.pointee.width) } ?? 0 } }
    var framebufferHeight: Int { onMessageQueue { activeClient.map { Int($0.pointee.height) } ?? 0 } }
    var framebufferBytesPerRow: Int {
        onMessageQueue {
            guard let client = activeClient else { return 0 }
            return Int(client.pointee.width) * Int(client.pointee.format.bitsPerPixel) / 8
        }
    }

    func withFramebuffer<T>(_ body: (UnsafeRawBufferPointer, Int, Int) -> T) -> T? {
        onMessageQueue {
            guard framebufferHasUpdate, let client = activeClient,
                  let pointer = client.pointee.frameBuffer else { return nil }
            let width = Int(client.pointee.width)
            let height = Int(client.pointee.height)
            let bpp = Int(client.pointee.format.bitsPerPixel) / 8
            let buffer = UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: width * height * bpp)
            return body(buffer, width, height)
        }
    }

    private func publishFrameReadiness(available: Bool, complete: Bool) {
        let continuations = frameReadiness.withLock { state -> [CheckedContinuation<Void, Error>] in
            state.available = available
            state.complete = complete
            guard !available || complete else { return [] }
            let waiting = state.waiters.values.compactMap { waiter -> CheckedContinuation<Void, Error>? in
                waiter.deadline?.cancel()
                let continuation = waiter.continuation
                waiter.continuation = nil
                return continuation
            }
            state.waiters.removeAll()
            return waiting
        }
        for continuation in continuations {
            if available { continuation.resume() }
            else { continuation.resume(throwing: VNCError.notConnected) }
        }
    }

    private func finishFrameWait(_ waiter: FrameWaiter, cancelled: Bool) {
        let continuation = frameReadiness.withLock { state -> CheckedContinuation<Void, Error>? in
            if cancelled { waiter.cancelled = true }
            guard state.waiters.removeValue(forKey: waiter.id) != nil else { return nil }
            waiter.deadline?.cancel()
            let continuation = waiter.continuation
            waiter.continuation = nil
            return continuation
        }
        guard let continuation else { return }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        else { continuation.resume(throwing: VNCError.sendFailed("No complete framebuffer update within 5 seconds")) }
    }

    /// Wait without occupying the native queue: it must keep receiving pixels.
    /// The independent deadline also completes while a native read is occupied.
    func waitForFramebuffer() async throws {
        let waiter = FrameWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let deadline = DispatchWorkItem { [weak self, weak waiter] in
                    guard let self, let waiter else { return }
                    self.finishFrameWait(waiter, cancelled: false)
                }
                let immediate = frameReadiness.withLock { state -> Result<Void, Error>? in
                    if waiter.cancelled { return .failure(CancellationError()) }
                    if !state.available { return .failure(VNCError.notConnected) }
                    if state.complete { return .success(()) }
                    waiter.continuation = continuation
                    waiter.deadline = deadline
                    state.waiters[waiter.id] = waiter
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
                else { scheduleFrameDeadline(.global(qos: .userInitiated), 5, deadline) }
            }
            try Task.checkCancellation()
        } onCancel: {
            self.finishFrameWait(waiter, cancelled: true)
        }
    }

    func frameUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.framebufferUpdateContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                self.framebufferUpdateContinuation = nil
            }
        }
    }

    // MARK: - Input

    func sendMouseEvent(x: Int, y: Int, buttonMask: Int = 0) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            messageQueue.async { [self] in
                guard let client = activeClient else {
                    continuation.resume(throwing: VNCError.notConnected)
                    return
                }
                if SendPointerEvent(client, Int32(x), Int32(y), Int32(buttonMask)) != 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VNCError.sendFailed("pointer event"))
                }
            }
        }
    }

    func sendKeyEvent(key: UInt32, down: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            messageQueue.async { [self] in
                guard let client = activeClient else {
                    continuation.resume(throwing: VNCError.notConnected)
                    return
                }
                // macOS Apple VNC expects Super_L/R for Command, not Meta_L/R
                var remappedKey = key
                if isMacOS {
                    if key == 0xFFE7 { remappedKey = 0xFFEB }
                    if key == 0xFFE8 { remappedKey = 0xFFEC }
                }
                let rfbDown: rfbBool = down ? -1 : 0
                if SendKeyEvent(client, remappedKey, rfbDown) != 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VNCError.sendFailed("key event"))
                }
            }
        }
    }

    func sendKeyTap(key: UInt32) async throws {
        try await sendKeyEvent(key: key, down: true)
        try await sendKeyEvent(key: key, down: false)
    }

    func sendClipboardText(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            messageQueue.async { [self] in
                guard let client = activeClient else {
                    continuation.resume(throwing: VNCError.notConnected)
                    return
                }
                var cStr = Array(text.utf8CString)
                let len = Int32(cStr.count - 1)
                if SendClientCutText(client, &cStr, len) != 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VNCError.sendFailed("clipboard text"))
                }
            }
        }
    }

    func requestFullUpdate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            messageQueue.async { [self] in
                guard let client = activeClient else {
                    continuation.resume(throwing: VNCError.notConnected)
                    return
                }
                if SendFramebufferUpdateRequest(
                    client, 0, 0,
                    Int32(client.pointee.width),
                    Int32(client.pointee.height),
                    0
                ) != 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VNCError.sendFailed("framebuffer update request"))
                }
            }
        }
    }

    // MARK: - Message Loop

    private func enqueuePoll(_ session: UUID) {
        guard wants(session) else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.clientSession == session, self.wants(session),
                  let client = self.client else { return }
            self.pendingWork = nil
            guard self.operations.poll(client, min(max(self.config.messageLoopInterval, 500), 250_000)) else {
                self.cleanupClient()
                guard self.wants(session) else { return }
                self.updateState(.error("Connection lost"))
                self.scheduleReconnect(session)
                return
            }
            guard self.wants(session) else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- self.lastUpdateRequestNs > 50_000_000 {
                self.operations.incrementalUpdate(client)
                self.lastUpdateRequestNs = now
            }
            self.enqueuePoll(session)
        }
        pendingWork = item
        schedule(messageQueue, 0, item)
    }

    private func scheduleReconnect(_ session: UUID) {
        guard wants(session) else { return }
        let attempts = min(max(config.maxReconnectAttempts, 0), 100)
        guard config.autoReconnect, reconnectCount < attempts else {
            desiredSession.withLock { if $0 == session { $0 = nil } }
            clientSession = nil
            updateState(.disconnected)
            return
        }
        reconnectCount += 1
        let base = config.reconnectDelay.isFinite ? min(max(config.reconnectDelay, 0.1), 30) : 2
        let delay = min(base * Double(min(reconnectCount, 5)), 30)
        log("Reconnecting (\(reconnectCount)/\(attempts)) in \(delay)s")
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.clientSession == session, self.wants(session) else { return }
            self.pendingWork = nil
            do {
                try self.attemptConnection(session)
            } catch {
                // The desired session survives failed attempts; only explicit
                // cancellation or exhausted policy disables further retries.
                guard self.wants(session) else { return }
                self.updateState(.error("Reconnect failed"))
                self.scheduleReconnect(session)
            }
        }
        pendingWork = item
        schedule(messageQueue, delay, item)
    }

    // MARK: - Logging

    func log(_ message: String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("[VNC \(timestamp())] \(message)\n".utf8))
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
