import Foundation

/// Diagnostics describe control flow and coverage only, never framebuffer,
/// clipboard, credentials, or server-supplied text. The native queue publishes
/// bounded snapshots so a blocked decoder cannot block the frame deadline.
enum VNCDecoderPhase: String, Codable, Sendable {
    case disconnected, initializing, idle, waitingForMessage
    case handlingServerMessage, requestingIncrementalUpdate
}

struct VNCFramebufferDiagnostics: Codable, Sendable {
    var connectionGeneration = 0
    // Accepted allocation attempts, including a later allocator failure.
    var allocations = 0
    var width = 0
    var height = 0
    var pixelsRemaining = 0
    var rectangles = 0
    var copyRectangles = 0
    var finishedUpdates = 0
    var rejectedRectangles = 0
    var skippedCopyRectangles = 0
    var complete = false
    var phase = VNCDecoderPhase.disconnected
    var lastCallbackAgeMilliseconds: UInt64?

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        // Only finite integer, boolean, and enum values enter this payload.
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Connection State

enum VNCConnectionState: Sendable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected(width: Int, height: Int)
    case error(String)

    var description: String {
        switch self {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case let .connected(w, h): "connected (\(w)×\(h))"
        case let .error(msg): "error: \(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Errors

enum VNCError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case alreadyConnected
    case messageLoopFailed
    case framebufferAllocationFailed
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to VNC server."
        case .connectionFailed(let msg): "VNC connection failed: \(msg)"
        case .alreadyConnected: "Already connected to a VNC server."
        case .messageLoopFailed: "VNC message loop encountered an error."
        case .framebufferAllocationFailed: "Failed to allocate framebuffer."
        case .sendFailed(let msg): "Failed to send VNC event: \(msg)"
        }
    }
}

// MARK: - Configuration

struct VNCConfiguration {
    var host: String = "127.0.0.1"
    var port: Int = 5900
    var username: String?
    var password: String?
    var bitsPerSample: Int32 = 8
    var samplesPerPixel: Int32 = 3
    var bytesPerPixel: Int32 = 4
    var connectTimeout: Int = 0
    var autoReconnect: Bool = true
    var reconnectDelay: TimeInterval = 2.0
    var maxReconnectAttempts: Int = 10
    var messageLoopInterval: UInt32 = 500
}
