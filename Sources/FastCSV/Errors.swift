import Foundation

public enum CSVErrors: Error {
    case fileIOError(Error)
    case bufferReadFailed
    case malformedFile
    case invalidQuoting
    case encodingNotSupported
    case invalidConfiguration
}
