import Darwin
import Foundation

// Compile only with the actual CredentialInput.swift helper in an owned native
// qualification target. It contains no VNC client and cannot open a connection.
@main
enum CredentialInputHarness {
    static func main() {
        do {
            let value = try CredentialInput.readInherited(fd: 3)
            var metadata = stat()
            guard fstat(3, &metadata) == -1, errno == EBADF else { exit(3) }
            let protocolBytes = FileHandle.standardInput.readDataToEndOfFile()
            let result: [String: Any] = [
                "accepted": true,
                "credentialBytes": value.utf8.count,
                "credentialMatches": value == "synthetic-ARD-π-\n",
                "protocolMatches": protocolBytes == Data("{\"method\":\"health\"}\n".utf8),
                "credentialDescriptorClosed": true,
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            // Never print received bytes or arbitrary error descriptions.
            let category: String
            switch error {
            case CredentialInputError.descriptor: category = "descriptor"
            case CredentialInputError.custody: category = "custody"
            case CredentialInputError.timeout: category = "timeout"
            case CredentialInputError.frame: category = "frame"
            default: category = "io"
            }
            var metadata = stat()
            let closed = fstat(3, &metadata) == -1 && errno == EBADF
            let result: [String: Any] = ["accepted": false, "category": category,
                                        "credentialDescriptorClosed": closed]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            }
            exit(2)
        }
    }
}
