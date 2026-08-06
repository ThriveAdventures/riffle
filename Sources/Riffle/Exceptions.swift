import Foundation
import RiffleShims

// Runs body, converting any Objective-C NSException into a thrown Swift
// error (and logging it). AVFoundation's engine and tap calls raise
// NSExceptions on stale device state; uncaught, those abort the process.
func riffleCatching<T>(_ label: String, _ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    let exception = withoutActuallyEscaping(body) { escapable -> Error? in
        RiffleTryCatch {
            result = Result { try escapable() }
        }
    }
    if let exception {
        Log.write("caught NSException in \(label): \(exception.localizedDescription)")
        throw exception
    }
    return try result!.get()
}
