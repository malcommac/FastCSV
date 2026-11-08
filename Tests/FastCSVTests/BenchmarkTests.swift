import Foundation
import Testing
@testable import FastCSV

// Benchmark on real data: Rome's GTFS feed.
//
// Run in release mode only, otherwise you measure the compiler:
//   swift test -c release -Xswiftc -enable-testing --filter Benchmark
//
// The suite is .serialized because Swift Testing runs tests in parallel by
// default: two concurrent benchmarks contend for CPU and memory, and the numbers
// become unreliable.
//
// Tests disable themselves if the feed is missing, so the suite stays green
// on machines that don't have it.
//
// File used for these tests is available in the GTFS static data:
// <https://dati.comune.roma.it/catalog/dataset/c_h501-d-9000/resource/266d82e1-ba53-4510-8a81-370880c4678f>
// Download and reference the local path in TestResources.swift

@Suite(.serialized, .enabled(if: gtfsAvailable))
struct Benchmark {

    /// The naive version tests to create the baseline.
    /// We'll use two variants:
    /// - using `components(separatedBy:)` which allocates strings for each field
    /// - using `split(separator:)` which uses `Substring` and avoid allocations
    @Test func parseAndAllocateNaive() throws {
        let clock = ContinuousClock()

        let rssBefore = residentMemoryMB()
        let t0 = clock.now
        let text = try String(contentsOf: gtfsURL, encoding: .utf8)
        let readTime = clock.now - t0
        let rssAfterRead = residentMemoryMB()

        // A — components(separatedBy:): allocates a `String` for each row and field
        func withComponents() -> (parse: Duration, allocate: Duration) {
            let lines = text.components(separatedBy: "\n")
            let headers = lines[0].components(separatedBy: ",")

            // Parse only: measure field splitting cost
            let tParse = clock.now
            var fieldCount = 0
            for i in 1..<lines.count {
                let fields = lines[i].components(separatedBy: ",")
                if fields.count == headers.count && !fields[0].isEmpty {
                    fieldCount += fields.count
                }
            }
            let parseTime = clock.now - tParse

            // Parse + allocate: measure total cost including object creation
            let tTotal = clock.now
            var rows = 0
            for i in 1..<lines.count {
                let fields = lines[i].components(separatedBy: ",")
                if fields.count == headers.count && !fields[0].isEmpty {
                    _ = StopTime(
                        trip_id: fields[0],
                        arrival_time: fields[1],
                        departure_time: fields[2],
                        stop_id: fields[3],
                        stop_sequence: Int(fields[4]) ?? 0,
                        stop_headsign: fields[5].isEmpty ? nil : fields[5],
                        pickup_type: Int(fields[6]),
                        drop_off_type: Int(fields[7]),
                        shape_dist_traveled: Double(fields[8]),
                        timepoint: Int(fields[9])
                    )
                    rows += 1
                }
            }
            let totalTime = clock.now - tTotal

            precondition(fieldCount > 0 && rows > 0)
            return (parseTime, totalTime)
        }

        // B — split(separator:): returns `Substring`, zero-copy slices
        func withSplit() -> (parse: Duration, allocate: Duration) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let headers = lines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)

            // Parse only: measure field splitting cost
            let tParse = clock.now
            var fieldCount = 0
            for i in 1..<lines.count {
                let fields = lines[i].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                if fields.count == headers.count && !fields[0].isEmpty {
                    fieldCount += fields.count
                }
            }
            let parseTime = clock.now - tParse

            // Parse + allocate: measure total cost including object creation
            let tTotal = clock.now
            var rows = 0
            for i in 1..<lines.count {
                let fields = lines[i].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                if fields.count == headers.count && !fields[0].isEmpty {
                    _ = StopTime(
                        trip_id: fields[0],
                        arrival_time: fields[1],
                        departure_time: fields[2],
                        stop_id: fields[3],
                        stop_sequence: Int(fields[4]) ?? 0,
                        stop_headsign: fields[5].isEmpty ? nil : fields[5],
                        pickup_type: Int(fields[6]),
                        drop_off_type: Int(fields[7]),
                        shape_dist_traveled: Double(fields[8]),
                        timepoint: Int(fields[9])
                    )
                    rows += 1
                }
            }
            let totalTime = clock.now - tTotal

            precondition(fieldCount > 0 && rows > 0)
            return (parseTime, totalTime)
        }

        // Run A, B, then B, A again. If allocator warmth mattered — warm allocator,
        // file already in page cache — the order would diverge and A vs B
        // comparisons would be meaningless.
        let a1 = withComponents()
        let rssPeak = residentMemoryMB()
        let b1 = withSplit()
        let b2 = withSplit()
        let a2 = withComponents()

        let driftA = abs(seconds(a1.allocate) - seconds(a2.allocate)) / seconds(a1.allocate) * 100
        let driftB = abs(seconds(b1.allocate) - seconds(b2.allocate)) / seconds(b1.allocate) * 100

        let allocateOnlyA = seconds(a1.allocate) - seconds(a1.parse)
        let allocateOnlyB = seconds(b1.allocate) - seconds(b1.parse)

        print("""

        ── parse and allocate naive (260 MB file) ──
          1. String(contentsOf:)         \(readTime)   (RSS +\(String(format: "%.0f", rssAfterRead - rssBefore)) MB)
          2a. components(separatedBy:) — parse only       \(String(format: "%.3f", seconds(a1.parse)))s   (RSS peak +\(String(format: "%.0f", rssPeak - rssBefore)) MB)
          2b. components(separatedBy:) — with objects     \(a1.allocate)
             ├─ object allocation overhead               \(String(format: "%.3f", allocateOnlyA))s
          3a. split(separator:) — parse only             \(String(format: "%.3f", seconds(b1.parse)))s
          3b. split(separator:) — with objects           \(b1.allocate)
             └─ object allocation overhead               \(String(format: "%.3f", allocateOnlyB))s

          order test — A again \(a2.allocate), B again \(b2.allocate)
          drift: A \(String(format: "%.1f", driftA))%, B \(String(format: "%.1f", driftB))%
        """)

        // If drift exceeded 15%, the comparison would be biased by allocator warmth
        // and pool behavior — the results wouldn't be publishable.
        // Threshold is higher because object allocation adds inherent variability.
        #expect(driftA < 15)
        #expect(driftB < 15)
    }

    @Test func parseAndAllocateFastCSV() throws {
        let clock = ContinuousClock()

        // Warmup: one empty pass loads the 260 MB into page cache.
        // Without it, the first measurement times disk, not code — the same read
        // takes ~0.19s with cached pages vs ~0.44s without caching.
        do {
            let warmup = try CSVReader(fileURL: gtfsURL, config: .init(hasHeaders: true))
            #expect(warmup.rowCount > 0)
        }

        // 1. Indexing: init performs mmap, file sniffing, and offset scanning
        let rssBefore = residentMemoryMB()
        let t0 = clock.now
        let reader = try CSVReader(fileURL: gtfsURL, config: .init(hasHeaders: true))
        let indexing = clock.now - t0
        let rssAfterIndex = residentMemoryMB()

        guard let iTrip = reader.columnIndex("trip_id"),
              let iArr = reader.columnIndex("arrival_time"),
              let iDep = reader.columnIndex("departure_time"),
              let iStop = reader.columnIndex("stop_id"),
              let iSeq = reader.columnIndex("stop_sequence"),
              let iHead = reader.columnIndex("stop_headsign"),
              let iPick = reader.columnIndex("pickup_type"),
              let iDrop = reader.columnIndex("drop_off_type"),
              let iDist = reader.columnIndex("shape_dist_traveled"),
              let iTime = reader.columnIndex("timepoint")
        else {
            Issue.record("unexpected header: \(reader.columnNames)")
            return
        }

        // 2a. Parse only: iterate rows splitting fields with empty body.
        // Isolates field-splitting cost from value materialization.
        var rowsVisited = 0
        let tSplit = clock.now
        reader.forEachRow { _ in rowsVisited += 1 }
        let splitOnly = clock.now - tSplit

        // 2b. Direct access with typed field readers, building the same StopTime
        var builtDirectly = 0
        let t1 = clock.now
        reader.forEachRow { row in
            _ = StopTime(
                trip_id: row.field(at: iTrip),
                arrival_time: row.field(at: iArr),
                departure_time: row.field(at: iDep),
                stop_id: row.field(at: iStop),
                stop_sequence: row.intField(at: iSeq) ?? 0,
                stop_headsign: row.isFieldEmpty(at: iHead) ? nil : row.field(at: iHead),
                pickup_type: row.intField(at: iPick),
                drop_off_type: row.intField(at: iDrop),
                shape_dist_traveled: Double(row.field(at: iDist)),
                timepoint: row.intField(at: iTime)
            )
            builtDirectly += 1
        }
        let direct = clock.now - t1

        // 2c. Same object but converting numbers via String:
        // the naive way, what you'd write without typed accessors.
        var builtViaStrings = 0
        let tStr = clock.now
        reader.forEachRow { row in
            _ = StopTime(
                trip_id: row.field(at: iTrip),
                arrival_time: row.field(at: iArr),
                departure_time: row.field(at: iDep),
                stop_id: row.field(at: iStop),
                stop_sequence: Int(row.field(at: iSeq)) ?? 0,
                stop_headsign: row.field(at: iHead).isEmpty ? nil : row.field(at: iHead),
                pickup_type: Int(row.field(at: iPick)),
                drop_off_type: Int(row.field(at: iDrop)),
                shape_dist_traveled: Double(row.field(at: iDist)),
                timepoint: Int(row.field(at: iTime))
            )
            builtViaStrings += 1
        }
        let viaStrings = clock.now - tStr

        // 3. Same thing via Codable
        var decoded = 0
        let t2 = clock.now
        try reader.decode(StopTime.self) { _ in decoded += 1 }
        let codable = clock.now - t2

        #expect(rowsVisited == reader.rowCount)
        #expect(builtDirectly == decoded)
        #expect(builtDirectly == builtViaStrings)
        #expect(builtDirectly == reader.rowCount)

        let allocateDirect = seconds(direct) - seconds(splitOnly)
        let allocateViaStrings = seconds(viaStrings) - seconds(splitOnly)

        print("""

        ── parse and allocate FastCSV (\(reader.rowCount) rows) ──
          1. indexing                    \(indexing)   (RSS +\(String(format: "%.0f", rssAfterIndex - rssBefore)) MB)
          2a. parse only                 \(splitOnly)
          2b. with typed readers         \(direct)
             └─ allocation overhead       \(String(format: "%.3f", allocateDirect))s
          2c. with String conversion     \(viaStrings)
             └─ allocation overhead       \(String(format: "%.3f", allocateViaStrings))s
          3. Codable                     \(codable)

          parse cost                     \(String(format: "%.3f", seconds(splitOnly)))s
          allocate (typed readers)       \(String(format: "%.3f", allocateDirect))s
          allocate (String conversion)   \(String(format: "%.3f", allocateViaStrings))s
          typed readers are \(String(format: "%.1f", allocateViaStrings / allocateDirect))x faster than String conversion
          Codable costs \(String(format: "%.1f", seconds(codable) / seconds(direct)))x vs direct access

        """)
    }
}

private struct StopTime: Decodable {
    let trip_id: String
    let arrival_time: String
    let departure_time: String
    let stop_id: String
    let stop_sequence: Int
    let stop_headsign: String?
    let pickup_type: Int?
    let drop_off_type: Int?
    let shape_dist_traveled: Double?
    let timepoint: Int?
}
