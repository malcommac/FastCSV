import Foundation
import BenchSupport
import FastCSV

// stop_times.txt only: the real workload, converting times and integers from
// bytes. `bytes` here is a checksum of the converted values, not a byte count.
try measure { url in
    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))
    let arrival = reader.columnIndex("arrival_time")!
    let departure = reader.columnIndex("departure_time")!
    let sequence = reader.columnIndex("stop_sequence")!
    var rows = 0
    var sum = 0
    reader.forEachRow { row in
        sum &+= (row.timeField(at: arrival) ?? 0) &+ (row.timeField(at: departure) ?? 0)
        sum &+= row.intField(at: sequence) ?? 0
        rows += 1
    }
    return (rows, sum)
}
