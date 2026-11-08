import Foundation
import Testing
@testable import FastCSV

// Measure performance reading a large CSV file with warm cache.
// Run with: swift test -c release -Xswiftc -enable-testing
@Test func decodeLongCSV() async throws {
    var config = CSVReaderConfig()
    config.hasHeaders = true

    // Warmup: one empty pass loads the file into page cache.
    // Without it, measurement times disk I/O instead of parsing code.
    do {
        let warmup = try CSVReader(fileURL: gtfsURL, config: config)
        precondition(warmup.rowCount > 0)
    }

    print("Reading \(gtfsURL.absoluteString)")

    let start = Date.now
    let reader = try CSVReader(fileURL: gtfsURL, config: config)
    let end = Date.now.timeIntervalSince1970 - start.timeIntervalSince1970

    print("Headers: \(reader.columnNames.joined(separator: " - "))")
    print("Rows: \(reader.rowCount)")
    print("Finished in \(end)")
}

// Verify line indexing respects quoted fields (three newlines, two rows).
// Tests that quote tracking works: position 4 is inside quotes,
// position 16 is phantom row that must be discarded.
// Wrong offsets [0, 5, 10] mean broken quote tracking;
// wrong offsets [0, 10, 16] mean phantom row wasn't removed.
@Test func indexIgnoreNewlineInsideQuote() {
    //          a  ,  "  x  \n y  "  ,  b  \n
    // index    0  1  2  3  4  5  6  7  8  9
    let bytes = Array("a,\"x\ny\",b\n1,2,3\n".utf8)
    
    let offsets = bytes.withUnsafeBufferPointer { buf in
        CSVReader.indexLines(
            base: buf.baseAddress!,
            count: buf.count,
            quoteByte: 0x22,
            delimiterByte: 0x2C,
            trackQuotes: true
        )
    }

    #expect(offsets == [0, 10])
}

// Parse CSV with escaped quotes and newlines, verifying proper quote handling.
// The raw string delimiter #""" lets us write quotes literally (no escaping needed).
// Each #expect targets a different edge case:
// - stray quote in unquoted field is literal
// - newline inside quotes doesn't break row
// - "" becomes a single quote
// - header row isn't counted
// Swift multiline literal lacks final \n, testing row termination by byte count too.
@Test func readCSVWithTraps() throws {
    let csv = #"""
    prodotto,note,prezzo
    monitor 24" full HD,niente,199
    tastiera,"riga uno
    riga due",49
    mouse,"disse ""ciao""",19
    """#
    
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fast-csv-\(UUID().uuidString).csv")
    try csv.write(to: url, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: url)
    }
    
    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))
    
    #expect(reader.columnNames == ["prodotto", "note", "prezzo"])
    #expect(reader.rowCount == 3)

    var rows: [[String]] = []
    reader.forEachRow { row in
        rows.append((0..<row.count).map { row.field(at: $0) })
    }

    #expect(rows[0] == ["monitor 24\" full HD", "niente", "199"])
    #expect(rows[1] == ["tastiera", "riga uno\nriga due", "49"])
    #expect(rows[2] == ["mouse", "disse \"ciao\"", "19"])
}

// Verify fast path splits on every newline (no quote tracking).
// Same bytes as quote test but opposite expectation.
// [0, 5, 10] is not wrong per se — it's the contract of fast path
// when caller promises no newlines inside fields.
@Test func fastPathSplitsOnEveryNewline() {
    let bytes = Array("a,\"x\ny\",b\n1,2,3\n".utf8)
    
    let offsets = bytes.withUnsafeBufferPointer { buf in
        CSVReader.indexLines(
            base: buf.baseAddress!,
            count: buf.count,
            quoteByte: 0x22,
            delimiterByte: 0x2C,
            trackQuotes: false
        )
    }

    #expect(offsets == [0, 5, 10])
}

// Verify Windows \r\n line endings are handled (trim \r correctly).
// Here the literal is a normal string (not raw), so \r\n are real escape sequences in the file.
// Broken \r trimming would give ["prodotto", "prezzo\r"] instead of expected.
// This is a prod bug that manifests as "string comparison never matches" puzzles.
@Test func handlesWindowsLineEndings() throws {
    let csv = "prodotto,prezzo\r\nmouse,19\r\ntastiera,49\r\n"

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try csv.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))

    #expect(reader.columnNames == ["prodotto", "prezzo"])
    #expect(reader.rowCount == 2)

    var rows: [[String]] = []
    reader.forEachRow { row in
        rows.append((0..<row.count).map { row.field(at: $0) })
    }

    #expect(rows == [["mouse", "19"], ["tastiera", "49"]])
}

// Verify UTF-8 BOM is skipped at file start.
@Test func skipsUTF8BOM() throws {
    let csv = "\u{FEFF}prodotto,prezzo\r\nmouse,19\r\ntastiera,49\r\n"

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try csv.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))

    #expect(reader.columnNames == ["prodotto", "prezzo"])
    #expect(reader.rowCount == 2)

    var rows: [[String]] = []
    reader.forEachRow { row in
        rows.append((0..<row.count).map { row.field(at: $0) })
    }

    #expect(rows == [["mouse", "19"], ["tastiera", "49"]])
}

// Verify integer field parsing handles six edge cases:
// normal number, negative, quoted number, non-numeric text, empty field, overflow.
// Overflow must return nil (not crash from silent truncation).
@Test func intFieldEdgeCases() throws {
    let csv = "a,b,c,d,e,f\n42,-7,\"99\",abc,,999999999999999999999999\n"

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try csv.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))

    var row: [Int?] = []
    reader.forEachRow { r in
        row = (0..<r.count).map { r.intField(at: $0) }
    }

    #expect(row == [42, -7, 99, nil, nil, nil])
}

// Verify nested iteration doesn't corrupt outer row's field cache.
// Read field before and after inner loop.
// If buffer is shared, inner loop leaves last row's ranges in it,
// corrupting outer read: would get ["r0a/r2a", "r1a/r2a", "r2a/r2a"].
@Test func nestedIterationDoesNotCorruptOuterRow() throws {
    let csv = "r0a,r0b\nr1a,r1b\nr2a,r2b\n"

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try csv.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try CSVReader(fileURL: url)

    var observations: [String] = []
    reader.forEachRow { fuori in
        let prima = fuori.field(at: 0)
        reader.forEachRow { _ in }
        let dopo = fuori.field(at: 0)
        observations.append("\(prima)/\(dopo)")
    }

    #expect(observations == ["r0a/r0a", "r1a/r1a", "r2a/r2a"])
}

// Verify boolean field parsing recognizes 1, TRUE as true; f, no, non-matching as false.
@Test func boolFieldEdgeCases() throws {
    let csv = "a,b,c,d,e,f\n1,TRUE,f,no,maybe,\n"

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try csv.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))

    var values: [Bool?] = []
    reader.forEachRow { r in
        values = (0..<r.count).map { r.boolField(at: $0) }
    }

    #expect(values == [true, true, false, false, nil, nil])
}

/// Reference: the original String-based implementation, kept as the oracle.
private func referenceBool(_ bytes: [UInt8]) -> Bool? {
    var field = bytes[...]
    if field.count >= 2, field.first == 0x22, field.last == 0x22 {
        field = field.dropFirst().dropLast()
    }
    guard !field.isEmpty, field.count <= 5 else { return nil }

    switch String(decoding: field, as: UTF8.self).lowercased() {
    case "1", "t", "y", "true", "yes":   return true
    case "0", "f", "n", "false", "no":   return false
    default:                              return nil
    }
}

// Verify byte-level boolField matches the String + lowercased() reference on every
// 1-2 byte input, every case permutation of the word tokens, and non-ASCII near misses.
@Test func boolFieldMatchesReference() {
    var inputs: [[UInt8]] = []

    for a in 0...255 {
        inputs.append([UInt8(a)])
        for b in 0...255 { inputs.append([UInt8(a), UInt8(b)]) }
    }

    for token in ["yes", "true", "false"] {
        let chars = Array(token.utf8)
        for mask in 0..<(1 << chars.count) {
            let variant = chars.enumerated().map { i, c in
                mask & (1 << i) != 0 ? c & ~0x20 : c
            }
            inputs.append(variant)
            inputs.append([0x22] + variant + [0x22])
        }
    }

    for s in ["", "\"\"", "\"", "tru", "truee", "fals", "falsee", "ye", "yess",
              "maybe", "nope", "\"1\"", "\"no", "no\"", "TRUE ", " true",
              "çà", "trüe", "ſ", "\u{212A}", "ｔｒｕｅ", "false1"] {
        inputs.append(Array(s.utf8))
    }

    for input in inputs {
        // Trailing padding byte keeps the base pointer valid for empty inputs.
        let padded = input + [0]
        let actual = padded.withUnsafeBufferPointer { buf in
            [0..<input.count].withUnsafeBufferPointer { fields in
                CSVRow(base: buf.baseAddress!, fields: fields, quoteByte: 0x22).boolField(at: 0)
            }
        }
        #expect(actual == referenceBool(input), "input \(input)")
    }
}
