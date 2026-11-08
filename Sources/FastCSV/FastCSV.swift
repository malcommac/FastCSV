import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Powers of ten that a Double represents exactly.
private let exactPowersOfTen: [Double] = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
]

public struct CSVReaderConfig {
    public var delimiter: Character
    public var bufferSize: Int
    public var encoding: String.Encoding
    public var quoteCharacter: Character
    public var hasHeaders: Bool

    public init(
        delimiter: Character = ",",
        bufferSize: Int = 65536,
        encoding: String.Encoding = .utf8,
        quoteCharacter: Character = "\"",
        hasHeaders: Bool = false,
    ) {
        self.delimiter = delimiter
        self.bufferSize = bufferSize
        self.encoding = encoding
        self.quoteCharacter = quoteCharacter
        self.hasHeaders = hasHeaders
    }
}

public final class CSVReader: @unchecked Sendable {
    private let fileURL: URL
    private let config: CSVReaderConfig
    private let fileDescriptor: Int32
    private let quoteByte: UInt8
    private let delimiterByte: UInt8

    public private(set) var columnNames: [String] = []

    private var columnIndexByName: [String: Int] = [:]

    public init(fileURL: URL, config: CSVReaderConfig = .init()) throws(CSVErrors) {
        guard let quoteByte = config.quoteCharacter.asciiValue,
              let delimiterByte = config.delimiter.asciiValue,
              config.bufferSize > 0 else {
            throw CSVErrors.invalidConfiguration
        }

        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw CSVErrors.fileIOError(POSIXError(.ENOENT))
        }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw CSVErrors.fileIOError(POSIXError(.EIO))
        }

        guard info.st_size > 0 else {
            close(fd)
            throw CSVErrors.malformedFile
        }

        self.fileURL = fileURL
        self.config = config
        self.fileDescriptor = fd
        self.quoteByte = quoteByte
        self.delimiterByte = delimiterByte

        if config.hasHeaders {
            readHeader()
        }
    }

    deinit {
        close(fileDescriptor)
    }

    /// Number of data rows, header excluded.
    ///
    /// Scans the whole file on every access, so read it once and keep the value.
    public var rowCount: Int {
        var rows = 0
        forEachRawRow { _, _, _, _ in
            rows += 1
            return true
        }
        return max(0, rows - (config.hasHeaders ? 1 : 0))
    }

    public func columnIndex(_ name: String) -> Int? {
        columnIndexByName[name]
    }

    /// Calls `body` for each data row, reading the file through a fixed-size buffer.
    ///
    /// The `CSVRow` is only valid inside `body`. A read error after the reader has
    /// been created stops the process, since the closure cannot report it.
    public func forEachRow(_ body: (CSVRow) -> Void) {
        // Pre-sized from the header: rows almost always have that many fields.
        var ranges = [Range<Int>](repeating: 0..<0, count: max(columnNames.count, 8))
        var skipHeader = config.hasHeaders

        forEachRawRow { base, start, end, hasQuotes in
            if skipHeader {
                skipHeader = false
                return true
            }

            let count = splitFieldsGrowing(
                base: base, start: start, end: end, hasQuotes: hasQuotes, into: &ranges
            )

            ranges.withUnsafeBufferPointer { buf in
                body(CSVRow(base: base,
                            fields: UnsafeBufferPointer(rebasing: buf[0..<count]),
                            quoteByte: quoteByte))
            }
            return true
        }
    }

    private func readHeader() {
        var ranges = [Range<Int>](repeating: 0..<0, count: 64)

        forEachRawRow { base, start, end, hasQuotes in
            let count = splitFieldsGrowing(
                base: base, start: start, end: end, hasQuotes: hasQuotes, into: &ranges
            )
            columnNames = ranges.withUnsafeBufferPointer { buf in
                let header = CSVRow(base: base,
                                    fields: UnsafeBufferPointer(rebasing: buf[0..<count]),
                                    quoteByte: quoteByte)
                return (0..<header.count).map { header.field(at: $0) }
            }
            return false
        }

        columnIndexByName = Dictionary(
            columnNames.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Delivers each row as a byte range of an internal buffer, without its line ending.
    /// `body` returns `false` to stop early.
    ///
    /// Each call owns its buffer and file position, so iterations can be nested.
    /// A row that doesn't fit makes the buffer grow, and is scanned again from its
    /// start after each refill: rows are short, and doubling keeps long ones linear.
    private func forEachRawRow(
        _ body: (_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ hasQuotes: Bool) -> Bool
    ) {
        var capacity = config.bufferSize
        var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var fileOffset: off_t = 0
        var length = 0
        var position = 0
        var checkedBOM = false

        while true {
            if position > 0 {
                memmove(buffer, buffer + position, length - position)
                length -= position
                position = 0
            }

            if length == capacity {
                capacity *= 2
                let larger = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                larger.update(from: buffer, count: length)
                buffer.deallocate()
                buffer = larger
            }

            let received = pread(fileDescriptor, buffer + length, capacity - length, fileOffset)
            if received < 0 {
                if errno == EINTR { continue }
                fatalError("FastCSV: read failed with errno \(errno)")
            }
            let reachedEnd = received == 0
            fileOffset += off_t(received)
            length += received

            if !checkedBOM {
                if length < 3 && !reachedEnd { continue }
                checkedBOM = true
                if length >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF {
                    position = 3
                }
            }

            let base = UnsafePointer(buffer)

            // The sniff: a row always starts outside quotes, so a buffer with no
            // quote byte can use the memchr paths whatever the rest of the file holds.
            let hasQuotes = position < length
                && memchr(base + position, Int32(quoteByte), length - position) != nil

            while position < length,
                  let newline = Self.rowEnd(
                    base: base, from: position, count: length,
                    quoteByte: quoteByte, delimiterByte: delimiterByte, trackQuotes: hasQuotes
                  ) {
                let start = position
                position = newline + 1
                guard body(base, start, Self.trimmedEnd(base, start: start, end: newline), hasQuotes) else {
                    return
                }
            }

            if reachedEnd {
                if position < length {
                    // Only an unterminated quoted field can leave a newline here.
                    let end = length > position && base[length - 1] == 0x0A ? length - 1 : length
                    _ = body(base, position, Self.trimmedEnd(base, start: position, end: end), hasQuotes)
                }
                return
            }
        }
    }

    @inline(__always)
    private static func trimmedEnd(_ base: UnsafePointer<UInt8>, start: Int, end: Int) -> Int {
        end > start && base[end - 1] == 0x0D ? end - 1 : end
    }

    /// Splits the row, growing the buffer if an irregular row has more fields than expected.
    private func splitFieldsGrowing(
        base: UnsafePointer<UInt8>, start: Int, end: Int, hasQuotes: Bool,
        into ranges: inout [Range<Int>]
    ) -> Int {
        while true {
            if let n = ranges.withUnsafeMutableBufferPointer({
                splitFields(base: base, start: start, end: end, hasQuotes: hasQuotes, into: $0)
            }) {
                return n
            }
            ranges = [Range<Int>](repeating: 0..<0, count: max(ranges.count * 2, 8))
        }
    }

    /// Writes the fields into `ranges` and returns how many it wrote, or `nil`
    /// if the buffer is too small.
    ///
    /// Writes by index instead of using `append`: over millions of rows with about
    /// ten fields each, the capacity and COW uniqueness check of every `append`
    /// becomes the dominant cost.
    private func splitFields(
        base: UnsafePointer<UInt8>,
        start: Int,
        end: Int,
        hasQuotes: Bool,
        into ranges: UnsafeMutableBufferPointer<Range<Int>>
    ) -> Int? {
        var n = 0

        // No quote byte in the buffer: every delimiter is a real delimiter,
        // and finding them with memchr is cheaper than the state machine.
        guard hasQuotes else {
            var fieldStart = start
            var pos = start
            while pos < end,
                  let hit = memchr(base + pos, Int32(delimiterByte), end - pos) {
                let i = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                guard n < ranges.count else { return nil }
                ranges[n] = fieldStart..<i
                n += 1
                fieldStart = i + 1
                pos = i + 1
            }
            guard n < ranges.count else { return nil }
            ranges[n] = fieldStart..<end
            return n + 1
        }

        var fieldStart = start
        var i = start
        var atFieldStart = true
        var fieldIsQuoted = false
        var inQuotes = false

        while i < end {
            let b = base[i]

            if atFieldStart {
                atFieldStart = false
                if b == quoteByte {
                    fieldIsQuoted = true
                    inQuotes = true
                    i += 1
                    continue
                }
                fieldIsQuoted = false
            }

            if fieldIsQuoted && b == quoteByte {
                inQuotes.toggle()
            } else if !inQuotes && b == delimiterByte {
                guard n < ranges.count else { return nil }
                ranges[n] = fieldStart..<i
                n += 1
                fieldStart = i + 1
                atFieldStart = true
                fieldIsQuoted = false
            }

            i += 1
        }

        guard n < ranges.count else { return nil }
        ranges[n] = fieldStart..<end
        return n + 1
    }

    /// The position of the newline ending the row that starts at `start`,
    /// or `nil` if the row doesn't end before `count`.
    static func rowEnd(
        base: UnsafePointer<UInt8>,
        from start: Int,
        count: Int,
        quoteByte: UInt8,
        delimiterByte: UInt8,
        trackQuotes: Bool
    ) -> Int? {
        guard trackQuotes else {
            guard let hit = memchr(base + start, 0x0A, count - start) else { return nil }
            return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
        }

        var atFieldStart = true
        var fieldIsQuoted = false
        var inQuotes = false

        for i in start..<count {
            let b = base[i]

            if atFieldStart {
                atFieldStart = false
                if b == quoteByte {
                    fieldIsQuoted = true
                    inQuotes = true
                    continue
                }
                fieldIsQuoted = false
            }

            if fieldIsQuoted && b == quoteByte {
                inQuotes.toggle()
            } else if !inQuotes {
                if b == delimiterByte {
                    atFieldStart = true
                    fieldIsQuoted = false
                } else if b == 0x0A {
                    return i
                }
            }
        }

        return nil
    }
}

public struct CSVRow {
    let base: UnsafePointer<UInt8>
    let fields: UnsafeBufferPointer<Range<Int>>
    let quoteByte: UInt8

    public var count: Int {
        fields.count
    }
    
    public subscript(safe index: Int) -> String? {
        index >= 0 && index < fields.count ? field(at: index) : nil
    }
    
    public func field(at index: Int) -> String {
        let range = fields[index]
        guard !range.isEmpty else {
            return ""
        }
        
        let quoted = range.count >= 2 &&
            base[range.lowerBound] == quoteByte &&
            base[range.upperBound - 1] == quoteByte
        
        // plain field
        guard quoted else {
            return decode(range)
        }
        
        let inner = (range.lowerBound + 1)..<(range.upperBound - 1)
        
        // quoted field without escapes
        var hasEscapes = false
        for i in inner where base[i] == quoteByte {
            hasEscapes = true
            break
        }
        
        // quoted field with escapes
        guard hasEscapes else {
            return decode(inner)
        }
        
        var bytes = [UInt8]()
        bytes.reserveCapacity(inner.count)
        var i = inner.lowerBound
        while i < inner.upperBound {
            let b = base[i]
            bytes.append(b)
            i += (b == quoteByte) ? 2 : 1 // keep only one quote of each `""`
        }
        
        return String(decoding: bytes, as: UTF8.self)
    }
    
    public func boolField(at index: Int) -> Bool? {
        let range = unquotedRange(at: index)

        guard !range.isEmpty, range.count <= 5 else { return nil }

        // Ten ASCII tokens of 1-5 bytes: the length selects the only candidate.
        // `| 0x20` lowercases letters; digits must be compared exactly,
        // because `0x11 | 0x20` would also yield '1'.
        let p = base + range.lowerBound
        @inline(__always) func folded(_ i: Int) -> UInt8 {
            p[i] | 0x20
        }

        switch range.count {
        case 1:
            switch p[0] {
            case UInt8(ascii: "1"): return true
            case UInt8(ascii: "0"): return false
            default: break
            }
            switch folded(0) {
            case UInt8(ascii: "t"), UInt8(ascii: "y"): return true
            case UInt8(ascii: "f"), UInt8(ascii: "n"): return false
            default: return nil
            }
        case 2:
            return folded(0) == UInt8(ascii: "n") && folded(1) == UInt8(ascii: "o")
                ? false : nil
        case 3:
            return folded(0) == UInt8(ascii: "y") && folded(1) == UInt8(ascii: "e")
                && folded(2) == UInt8(ascii: "s")
                ? true : nil
        case 4:
            return folded(0) == UInt8(ascii: "t") && folded(1) == UInt8(ascii: "r")
                && folded(2) == UInt8(ascii: "u") && folded(3) == UInt8(ascii: "e")
                ? true : nil
        default:
            return folded(0) == UInt8(ascii: "f") && folded(1) == UInt8(ascii: "a")
                && folded(2) == UInt8(ascii: "l") && folded(3) == UInt8(ascii: "s")
                && folded(4) == UInt8(ascii: "e")
                ? false : nil
        }
    }
    
    public func intField(at index: Int) -> Int? {
        let range = unquotedRange(at: index)

        guard !range.isEmpty else {
            return nil
        }
        
        var i = range.lowerBound
        var negative = false
        if base[i] == 0x2D { // minus sign
            negative = true
            i += 1
        } else if base[i] == 0x2B {
            i += 1 // plus sign
        }
        
        guard i < range.upperBound else {
            return nil
        }
        
        var result = 0
        while i < range.upperBound {
            let digit = Int(base[i]) &- 48               // '0'
            guard digit >= 0, digit <= 9 else { return nil }

            let (scaled, overflowA) = result.multipliedReportingOverflow(by: 10)
            guard !overflowA else { return nil }
            let (sum, overflowB) = scaled.addingReportingOverflow(digit)
            guard !overflowB else { return nil }

            result = sum
            i += 1
        }

        return negative ? -result : result
    }

    /// The field range without its surrounding quotes, if any.
    @inline(__always)
    func unquotedRange(at index: Int) -> Range<Int> {
        let range = fields[index]
        if range.count >= 2,
           base[range.lowerBound] == quoteByte,
           base[range.upperBound - 1] == quoteByte {
            return (range.lowerBound + 1)..<(range.upperBound - 1)
        }
        return range
    }

    /// Same result as `Double(String)`, bit for bit, without building the string.
    ///
    /// When the digits fit in 2^53 and the power of ten is within 10^22, both numbers
    /// are exact in a Double and a single IEEE division rounds correctly
    /// (Clinger's fast path). Everything else goes through the standard library.
    public func doubleField(at index: Int) -> Double? {
        let range = unquotedRange(at: index)
        guard !range.isEmpty else { return nil }

        var i = range.lowerBound
        var negative = false
        if base[i] == 0x2D { // -
            negative = true
            i += 1
        } else if base[i] == 0x2B { // +
            i += 1
        }

        let limit: UInt64 = 1 << 53
        var mantissa: UInt64 = 0
        var integerDigits = 0
        var fractionDigits = 0
        var sawPoint = false

        while i < range.upperBound {
            let b = base[i]
            let digit = b &- 0x30
            if digit <= 9 {
                guard mantissa <= (limit - 9) / 10 else { return Double(decode(range)) }
                mantissa = mantissa * 10 + UInt64(digit)
                if sawPoint { fractionDigits += 1 } else { integerDigits += 1 }
            } else if b == 0x2E && !sawPoint { // .
                sawPoint = true
            } else {
                return Double(decode(range)) // exponent, inf, nan, text
            }
            i += 1
        }

        // Let the standard library decide "1." and ".5", so behavior stays identical.
        guard integerDigits > 0, !sawPoint || fractionDigits > 0, fractionDigits <= 22 else {
            return Double(decode(range))
        }

        let value = Double(mantissa) / exactPowersOfTen[fractionDigits]
        return negative ? -value : value
    }

    /// An `H:MM:SS` time, in seconds. Hours may exceed 24, as in GTFS,
    /// where `25:30:00` is 1:30 AM after the service day.
    /// Accepts 1 to 4 hour digits; minutes and seconds must be below 60.
    public func timeField(at index: Int) -> Int? {
        let range = unquotedRange(at: index)
        guard range.count >= 7 else { return nil }

        let firstColon = range.upperBound - 6
        let secondColon = range.upperBound - 3
        guard base[firstColon] == 0x3A, base[secondColon] == 0x3A else { return nil }

        @inline(__always) func twoDigits(_ at: Int) -> Int? {
            let tens = base[at] &- 0x30
            let units = base[at + 1] &- 0x30
            guard tens <= 5, units <= 9 else { return nil }
            return Int(tens) * 10 + Int(units)
        }

        guard let minutes = twoDigits(firstColon + 1),
              let seconds = twoDigits(secondColon + 1) else { return nil }

        var hours = 0
        var i = range.lowerBound
        guard firstColon - i <= 4 else { return nil }
        while i < firstColon {
            let digit = base[i] &- 0x30
            guard digit <= 9 else { return nil }
            hours = hours * 10 + Int(digit)
            i += 1
        }

        return hours * 3600 + minutes * 60 + seconds
    }
    
    private func decode(_ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(start: base + range.lowerBound, count: range.count), as: UTF8.self)
    }
    
}
