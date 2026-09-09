import Foundation
import CLibVNCClient

// MARK: - C Callback Trampolines

/// Tag for rfbClientSetClientData/rfbClientGetClientData.
var vncBridgeTag: UInt8 = 0

/// Retrieve the VNCBridge instance from a C rfbClient pointer.
func bridge(from client: UnsafeMutablePointer<rfbClient>?) -> VNCBridge? {
    guard let client else { return nil }
    guard let ptr = rfbClientGetClientData(client, &vncBridgeTag) else { return nil }
    return Unmanaged<VNCBridge>.fromOpaque(ptr).takeUnretainedValue()
}

/// Called by LibVNC when the framebuffer needs to be (re)allocated.
func vncMallocFrameBuffer(_ client: UnsafeMutablePointer<rfbClient>?) -> rfbBool {
    guard let client else { return 0 }
    guard let b = bridge(from: client) else { return 0 }

    return b.allocateFramebuffer(for: client)
}

/// Called after a pixel rectangle is decoded, separately from cursor metadata.
func vncGotFrameBufferUpdate(_ client: UnsafeMutablePointer<rfbClient>?,
                            _ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32) {
    guard let client, let b = bridge(from: client) else { return }
    b.receivedFramebufferRectangle(for: client, x: x, y: y, width: width, height: height)
}

/// Called once when all rectangles in a framebuffer update have been received.
func vncFinishedFrameBufferUpdate(_ client: UnsafeMutablePointer<rfbClient>?) {
    guard let client else { return }
    guard let b = bridge(from: client) else { return }
    b.finishedFramebufferUpdate(for: client)
}

/// Called by LibVNC when a password is needed for VNC authentication.
func vncGetPassword(_ client: UnsafeMutablePointer<rfbClient>?) -> UnsafeMutablePointer<CChar>? {
    guard let b = bridge(from: client) else { return nil }
    guard let password = b.config.password else { return nil }
    return strdup(password)
}

/// Called when the server sends clipboard text.
func vncGotXCutText(
    _ client: UnsafeMutablePointer<rfbClient>?,
    _ text: UnsafePointer<CChar>?, _ len: Int32
) {
    // Intentionally ignore this unsolicited payload without reading it.
    // Clipboard content is neither retained nor logged.
}

// MARK: - ARD Authentication

/// Called by LibVNCClient when ARD auth needs username + password.
func vncGetCredential(
    _ client: UnsafeMutablePointer<rfbClient>?,
    _ credentialType: Int32
) -> UnsafeMutablePointer<rfbCredential>? {
    guard let client else { return nil }
    guard let b = bridge(from: client) else { return nil }

    if credentialType == rfbCredentialTypeUser {
        // ARD auth (type 30) requires credentials — this IS macOS
        b.isMacOS = true
        b.log("macOS detected via ARD credential request")

        let username = b.config.username ?? ""
        let password = b.config.password ?? ""

        let cred = UnsafeMutablePointer<rfbCredential>.allocate(capacity: 1)
        cred.pointee.userCredential.username = strdup(username)
        cred.pointee.userCredential.password = strdup(password)
        return cred
    }

    return nil
}
