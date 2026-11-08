import Foundation
import BenchSupport
import CSV

try measure { url in
    let reader = try CSVReader(stream: InputStream(url: url)!, hasHeaderRow: true)
    var rows = 0
    var bytes = 0
    while let row = reader.next() {
        for field in row { bytes += field.utf8.count }
        rows += 1
    }
    return (rows, bytes)
}
