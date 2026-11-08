import Foundation
import BenchSupport

// Baseline: what you would write without a library. Does not handle quoted fields.
try measure { url in
    let text = try String(contentsOf: url, encoding: .utf8)
    var rows = 0
    var bytes = 0
    for line in text.split(separator: "\n").dropFirst() {
        for field in line.split(separator: ",", omittingEmptySubsequences: false) {
            bytes += String(field).utf8.count
        }
        rows += 1
    }
    return (rows, bytes)
}
