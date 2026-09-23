import Foundation

/// Matches Petit4Send.exe MethodDef 41 (buttonDetectSyncKey_Click).
/// Arduino generates the pattern; Switch displays the result, not the serial reply.
enum SyncKeyDetection {
    static func run(exchange: ([UInt8], Bool) throws -> Void, pause: (TimeInterval) throws -> Void) throws {
        var failure: Error?
        do {
            try exchange([1] + [UInt8](repeating: 0, count: 11), true)
            try pause(4)
        } catch { failure = error }
        // Attempt both stops even if start, cancellation, or the first stop failed.
        // Ignore cancellation here so that it cannot leave detection running.
        for _ in 0..<2 {
            do { try exchange([UInt8](repeating: 0, count: 12), false) }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
}
