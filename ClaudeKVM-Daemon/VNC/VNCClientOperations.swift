import Foundation
import CLibVNCClient

/// All operations execute on VNCBridge's one native-client queue. The failed
/// initialize operation consumes its client, matching rfbInitClient's contract.
/// Tests replace these operations; production never selects another transport.
struct VNCClientOperations {
    typealias Client = UnsafeMutablePointer<rfbClient>
    var make: (VNCConfiguration) -> Client?
    var initialize: (Client) -> Bool
    var cleanup: (Client) -> Void
    var poll: (Client, UInt32, (VNCDecoderPhase) -> Void) -> Bool
    var incrementalUpdate: (Client) -> Void
    var allocateFramebuffer: (Int) -> UnsafeMutablePointer<UInt8>? = { malloc($0)?.assumingMemoryBound(to: UInt8.self) }
    var freeFramebuffer: (UnsafeMutablePointer<UInt8>) -> Void = { free($0) }

    static let native = VNCClientOperations(
        make: { rfbGetClient($0.bitsPerSample, $0.samplesPerPixel, $0.bytesPerPixel) },
        initialize: { client in
            var argc: Int32 = 0
            return rfbInitClient(client, &argc, nil) != 0
        },
        cleanup: release,
        poll: { client, interval, phase in
            phase(.waitingForMessage)
            defer { phase(.idle) }
            let result = WaitForMessage(client, interval)
            guard result > 0 else { return result == 0 }
            phase(.handlingServerMessage)
            return HandleRFBServerMessage(client) != 0
        },
        incrementalUpdate: { _ = SendIncrementalFramebufferUpdateRequest($0) }
    )

    static func release(_ client: Client) {
        // The bridge owns frameBuffer separately, including when initialization
        // fails after allocating it. rfbClientCleanup never frees that buffer.
        free(client.pointee.serverHost)
        client.pointee.serverHost = nil
        rfbClientCleanup(client)
    }
}

/// One outstanding poll OR retry item, owned and cancelled by the bridge.
/// The test scheduler retains work until explicitly advanced; it never sleeps.
typealias VNCWorkScheduler = (DispatchQueue, TimeInterval, DispatchWorkItem) -> Void

func scheduleVNCWork(on queue: DispatchQueue, after delay: TimeInterval, item: DispatchWorkItem) {
    if delay == 0 {
        queue.async(execute: item)
    } else {
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
