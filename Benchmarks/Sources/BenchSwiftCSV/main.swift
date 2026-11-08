import Foundation
import BenchSupport
import SwiftCSV

try measure { url in
    let csv = try CSV<Enumerated>(url: url, delimiter: .comma, encoding: .utf8, loadColumns: false)
    var rows = 0
    var bytes = 0
    try csv.enumerateAsArray(startAt: 1, rowLimit: nil) { row in
        for field in row { bytes += field.utf8.count }
        rows += 1
    }
    return (rows, bytes)
}
