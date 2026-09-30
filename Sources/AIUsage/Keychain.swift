import Foundation

enum Keychain {
    /// Reads a generic password through `/usr/bin/security`, the same tool Claude Code uses to store it.
    /// Going through `security` means the item's existing access list applies, so there is no
    /// keychain prompt and no dependency on this app's code signature. Read-only.
    static func readGenericPassword(service: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", service, "-w"]
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: FetchError("Could not run /usr/bin/security"))
                    return
                }
                // Read before waiting so a full pipe can't block the child.
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: FetchError("Keychain item \"\(service)\" not found"))
                }
            }
        }
    }
}
