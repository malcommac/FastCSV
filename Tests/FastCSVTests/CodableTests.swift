import Foundation
import Testing
@testable import FastCSV

// Codable decoding tests — separated from basic parsing tests for clear distinction
// between core reader functionality and Decodable integration.

private func withReader<R>(_ csv: String, _ body: (CSVReader) throws -> R) throws -> R {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try csv.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))
    return try body(reader)
}

/// Execute decoding expecting it to fail, and return the error.
private func decodingFailure<T: Decodable>(_ type: T.Type, csv: String) throws -> DecodingError? {
    try withReader(csv) { reader in
        do {
            try reader.decode(type) { _ in }
            return nil
        } catch let error as DecodingError {
            return error
        }
    }
}

// MARK: - Full roundtrip

private struct BusStop: Decodable, Equatable {
    enum Kind: String, Decodable {
        case bus, metro
    }

    let name: String
    let line: Int
    let lat: Double
    let active: Bool
    let note: String?
    let kind: Kind
}

// Verify full decoding pipeline with all primitive types and enums.
@Test func decodesAllPrimitivesPlusEnum() throws {
    let csv = """
    name,line,lat,active,note,kind
    Termini,64,41.9009,1,,metro
    Colosseo,75,41.8902,0,near the park,bus

    """

    let stops = try withReader(csv) { reader -> [BusStop] in
        var out: [BusStop] = []
        try reader.decode(BusStop.self) { out.append($0) }
        return out
    }

    #expect(stops == [
        BusStop(name: "Termini", line: 64, lat: 41.9009,
                active: true, note: nil, kind: .metro),
        BusStop(name: "Colosseo", line: 75, lat: 41.8902,
                active: false, note: "near the park", kind: .bus),
    ])
}

// MARK: - Two errors the container distinguishes

private struct WantsAMissingColumn: Decodable {
    let missing: String
}

// Verify keyNotFound error when decoding type expects missing column.
@Test func missingColumnThrowsKeyNotFound() throws {
    let error = try decodingFailure(
        WantsAMissingColumn.self,
        csv: "a,b\n1,2\n"
    )

    guard case .keyNotFound? = error else {
        Issue.record("expected keyNotFound, got \(String(describing: error))")
        return
    }
}

private struct ThreeColumns: Decodable {
    let a: String
    let b: String
    let c: String
}

// Verify valueNotFound error when row has fewer fields than expected.
@Test func shortRowThrowsValueNotFound() throws {
    let error = try decodingFailure(
        ThreeColumns.self,
        csv: "a,b,c\n1,2\n"
    )

    guard case .valueNotFound? = error else {
        Issue.record("expected valueNotFound, got \(String(describing: error))")
        return
    }
}

// MARK: - Non-convertible values

private struct SingleInt: Decodable {
    let n: Int
}

// Verify dataCorrupted error when field cannot convert to target numeric type.
@Test func nonNumericValueThrowsDataCorrupted() throws {
    let error = try decodingFailure(SingleInt.self, csv: "n\nabc\n")

    guard case .dataCorrupted? = error else {
        Issue.record("expected dataCorrupted, got \(String(describing: error))")
        return
    }
}

private struct SingleInt8: Decodable {
    let n: Int8
}

// Verify out-of-range integers fail rather than silently truncating.
@Test func outOfRangeIntegerIsNotTruncated() throws {
    // 300 fits in Int but not in Int8: must fail, not silently become 44.
    let error = try decodingFailure(SingleInt8.self, csv: "n\n300\n")

    guard case .dataCorrupted? = error else {
        Issue.record("expected dataCorrupted, got \(String(describing: error))")
        return
    }
}

private struct WithKind: Decodable {
    let kind: BusStop.Kind
}

// Verify unknown enum raw values fail decoding.
@Test func unknownEnumRawValueFails() throws {
    let error = try decodingFailure(WithKind.self, csv: "kind\ntram\n")
    #expect(error != nil)
}

// MARK: - Flat format only

private struct Nested: Decodable {
    struct Inner: Decodable {
        let x: Int
    }
    let inner: Inner
}

// Verify nested types are rejected with typeMismatch error.
@Test func nestedTypeIsRejectedClearly() throws {
    let error = try decodingFailure(Nested.self, csv: "inner\n1\n")

    guard case .typeMismatch? = error else {
        Issue.record("expected typeMismatch, got \(String(describing: error))")
        return
    }
}
