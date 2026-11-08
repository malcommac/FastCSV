import Testing
import Foundation
@testable import FastCSV

private func withFile<R>(_ bytes: [UInt8], _ body: (URL) throws -> R) throws -> R {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

private func rows(_ url: URL, bufferSize: Int, hasHeaders: Bool = false) throws -> [[String]] {
    let reader = try CSVReader(
        fileURL: url,
        config: .init(bufferSize: bufferSize, hasHeaders: hasHeaders)
    )
    var out: [[String]] = []
    reader.forEachRow { row in
        out.append((0..<row.count).map { row.field(at: $0) })
    }
    return out
}

private let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

// Every row boundary, quote and line ending lands on a buffer edge at some size.
@Test(arguments: [1, 2, 3, 4, 5, 7, 8, 13, 64, 65_536])
func resultsDoNotDependOnBufferSize(bufferSize: Int) throws {
    let text = "name,note\r\n\"a,b\",\"line one\r\nline two\"\r\nplain,\"said \"\"hi\"\"\"\r\n24\" monitor,x\nlast,row"
    let expected = [
        ["a,b", "line one\r\nline two"],
        ["plain", "said \"hi\""],
        ["24\" monitor", "x"],
        ["last", "row"],
    ]

    try withFile(bom + Array(text.utf8)) { url throws in
        #expect(try rows(url, bufferSize: bufferSize, hasHeaders: true) == expected)

        let reader = try CSVReader(fileURL: url, config: .init(bufferSize: bufferSize, hasHeaders: true))
        #expect(reader.columnNames == ["name", "note"])
        #expect(reader.rowCount == 4)
    }
}

// A row larger than the initial buffer makes it grow, in the middle of a file.
@Test func rowLongerThanTheBufferIsReadWhole() throws {
    let long = String(repeating: "x", count: 300_000)
    let quoted = String(repeating: "y\n", count: 100_000)
    let text = "a,b\n1,\(long)\n\"\(quoted)\",2\n3,4\n"

    try withFile(Array(text.utf8)) { url throws in
        let result = try rows(url, bufferSize: 16, hasHeaders: true)
        #expect(result.count == 3)
        #expect(result[0] == ["1", long])
        #expect(result[1] == [quoted, "2"])
        #expect(result[2] == ["3", "4"])
    }
}

// Quote tracking is decided per buffer: a quote far from the start must still work.
@Test func quotesFarFromTheStartAreHonored() throws {
    let plain = String(repeating: "aaa,bbb\n", count: 50_000)
    let text = plain + "\"c\nd\",e\nf,g\n"

    try withFile(Array(text.utf8)) { url throws in
        let result = try rows(url, bufferSize: 4096)
        #expect(result.count == 50_002)
        #expect(result[50_000] == ["c\nd", "e"])
        #expect(result[50_001] == ["f", "g"])
    }
}

@Test func lineEndingAndBOMSplitAcrossReads() throws {
    let bytes = bom + Array("a,b\r\n1,2\r\n".utf8)
    try withFile(bytes) { url throws in
        for size in 1...bytes.count + 1 {
            #expect(try rows(url, bufferSize: size) == [["a", "b"], ["1", "2"]], "size \(size)")
        }
    }
}

@Test func trailingNewlineDoesNotAddARow() throws {
    try withFile(Array("a\nb\n".utf8)) { url throws in
        #expect(try rows(url, bufferSize: 2) == [["a"], ["b"]])
    }
    try withFile(Array("a\nb".utf8)) { url throws in
        #expect(try rows(url, bufferSize: 2) == [["a"], ["b"]])
    }
}

@Test func fileHoldingOnlyABOMHasNoRows() throws {
    try withFile(bom) { url throws in
        #expect(try rows(url, bufferSize: 2) == [])
        #expect(try CSVReader(fileURL: url).rowCount == 0)
    }
}

@Test func headerOnlyFileHasNoDataRows() throws {
    try withFile(Array("a,b\r\n".utf8)) { url throws in
        let reader = try CSVReader(fileURL: url, config: .init(hasHeaders: true))
        #expect(reader.columnNames == ["a", "b"])
        #expect(reader.rowCount == 0)
    }
}

@Test func zeroBufferSizeIsRejected() throws {
    try withFile(Array("a\n".utf8)) { url throws in
        #expect(throws: CSVErrors.self) {
            _ = try CSVReader(fileURL: url, config: .init(bufferSize: 0))
        }
    }
}

@Test func directoryIsRejected() {
    #expect(throws: CSVErrors.self) {
        _ = try CSVReader(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()))
    }
}

@Test func concurrentIterationsDoNotInterfere() async throws {
    let text = (0..<20_000).map { "\($0),value\n" }.joined()
    try await withFileAsync(Array(text.utf8)) { url in
        let reader = try CSVReader(fileURL: url, config: .init(bufferSize: 128))
        let sums = await withTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<8 {
                group.addTask {
                    var sum = 0
                    reader.forEachRow { sum += $0.intField(at: 0) ?? 0 }
                    return sum
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(sums == Array(repeating: 199_990_000, count: 8))
    }
}

private func withFileAsync(_ bytes: [UInt8], _ body: (URL) async throws -> Void) async throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fastcsv-\(UUID().uuidString).csv")
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    try await body(url)
}
