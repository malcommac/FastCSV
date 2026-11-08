import Foundation
import BenchSupport
import FastCSV

// Every field materialized as a String, like the other parsers.
try measure { url in
    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))
    var rows = 0
    var bytes = 0
    reader.forEachRow { row in
        for i in 0..<row.count { bytes += row.field(at: i).utf8.count }
        rows += 1
    }
    return (rows, bytes)
}
