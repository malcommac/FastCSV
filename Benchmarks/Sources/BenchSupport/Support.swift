import Foundation

/// Runs `body` on the file given as first argument and prints one line:
/// seconds, rows and total UTF-8 bytes of the fields read. The two totals let
/// `run.py` check that every parser saw the same data.
public func measure(_ body: (URL) throws -> (rows: Int, bytes: Int)) rethrows {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let clock = ContinuousClock()
    let start = clock.now
    let result = try body(url)
    let elapsed = clock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    print("\(seconds) \(result.rows) \(result.bytes)")
}
