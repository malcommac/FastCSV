import Foundation
import BenchSupport
import CodableCSV

try measure { url in
    let reader = try CSVReader(input: url) { $0.headerStrategy = .firstLine }
    var rows = 0
    var bytes = 0
    while let row = try reader.readRow() {
        for field in row { bytes += field.utf8.count }
        rows += 1
    }
    return (rows, bytes)
}
