import Testing
import Foundation
@testable import FastCSV

/// Runs `body` on a row holding `text` as its only field.
private func withSingleField<R>(_ text: String, _ body: (CSVRow) -> R) -> R {
    // Trailing padding byte keeps the base pointer valid for empty inputs.
    let bytes = Array(text.utf8) + [0]
    return bytes.withUnsafeBufferPointer { buffer in
        [0..<(bytes.count - 1)].withUnsafeBufferPointer { fields in
            body(CSVRow(base: buffer.baseAddress!, fields: fields, quoteByte: 0x22))
        }
    }
}

private func sameBits(_ a: Double?, _ b: Double?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return x.bitPattern == y.bitPattern || (x.isNaN && y.isNaN)
    default: return false
    }
}

/// Deterministic generator, so a failure can be reproduced.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// Verify doubleField agrees with Double(String) on edge cases: signs, partial
// forms, exponents, specials, the 2^53 boundary and non-ASCII digits.
@Test func doubleFieldMatchesStandardLibrary() {
    let inputs = [
        "0", "-0", "+0", "0.0", "-0.0", "1", "1.", ".5", "-.5", "+.5", ".", "-", "+",
        "1.5", "41.902782", "12.496366", "41.90278212345678",
        "1e3", "1E3", "1e-3", "1.5e300", "1e400", "1e-400",
        "inf", "-inf", "nan", "infinity", "0x10", "0x1p3",
        " 1", "1 ", "1,5", "1.2.3", "--1", "+-1", "abc",
        "9007199254740991", "9007199254740992", "9007199254740993",
        "123456789012345678901234567890",
        "0.1", "0.2", "0.30000000000000004", "00001.5000",
        "0.0000000000000000000001", "0.00000000000000000000001",
        "1.7976931348623157e308", "4.9e-324", "١", "1٫5",
    ]

    for input in inputs {
        let actual = withSingleField(input) { $0.doubleField(at: 0) }
        #expect(sameBits(actual, Double(input)), "input <\(input)>")
    }
}

@Test func doubleFieldHandlesQuotesAndEmptyFields() {
    #expect(withSingleField("\"2.5\"") { $0.doubleField(at: 0) } == 2.5)
    #expect(withSingleField("\"abc\"") { $0.doubleField(at: 0) } == nil)
    #expect(withSingleField("") { $0.doubleField(at: 0) } == nil)
    #expect(withSingleField("\"\"") { $0.doubleField(at: 0) } == nil)
}

// Verify doubleField agrees with Double(String) to the bit on random decimals of
// every length around the fast path limits.
@Test func doubleFieldMatchesStandardLibraryOnRandomDecimals() {
    var generator = SplitMix64(state: 42)

    for _ in 0..<100_000 {
        let length = Int.random(in: 1...20, using: &generator)
        var digits = String((0..<length).map { _ in
            Character(UnicodeScalar(UInt8.random(in: 0x30...0x39, using: &generator)))
        })
        let point = Int.random(in: 0...length, using: &generator)
        digits.insert(".", at: digits.index(digits.startIndex, offsetBy: point))
        let input = Bool.random(using: &generator) ? "-" + digits : digits

        let actual = withSingleField(input) { $0.doubleField(at: 0) }
        #expect(sameBits(actual, Double(input)), "input <\(input)>")
    }
}

@Test(arguments: [
    ("07:28:00", 26_880),
    ("7:28:00", 26_880),
    ("00:00:00", 0),
    ("24:00:00", 86_400),
    ("30:40:00", 110_400),
    ("100:00:01", 360_001),
    ("1000:00:00", 3_600_000),
    ("\"07:28:00\"", 26_880),
] as [(String, Int)])
func timeFieldParsesValidTimes(input: String, expected: Int) {
    #expect(withSingleField(input) { $0.timeField(at: 0) } == expected)
}

@Test(arguments: [
    "", "\"\"", "07:28", "07:60:00", "07:00:60", "a7:00:00", "07-00-00", ":00:00",
    "07:0a:00", "07:00:0", "10000:00:00", " 7:00:00", "-7:00:00", "07:28:00:00",
])
func timeFieldRejectsInvalidTimes(input: String) {
    #expect(withSingleField(input) { $0.timeField(at: 0) } == nil)
}

// Verify the typed accessors through the real reader, on a file with quoted fields.
@Test func typedAccessorsReadARealFile() throws {
    let csv = "lat,time,empty\n41.902782,25:30:00,\n\"-12.5\",\"07:00:00\",\"\"\n"

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try csv.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))

    var doubles: [Double?] = []
    var times: [Int?] = []
    var emptiness: [Bool] = []
    reader.forEachRow { row in
        doubles.append(row.doubleField(at: 0))
        times.append(row.timeField(at: 1))
        emptiness.append(row.isFieldEmpty(at: 2))
    }

    #expect(doubles == [41.902782, -12.5])
    #expect(times == [91_800, 25_200])
    #expect(emptiness == [true, true])
}
