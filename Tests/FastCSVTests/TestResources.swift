import Foundation

// Relative to this file, so the package can move without breaking the benchmarks.
let gtfsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("rome_static_gtfs/stop_times.txt")

let gtfsAvailable = FileManager.default.fileExists(atPath: gtfsURL.path)
