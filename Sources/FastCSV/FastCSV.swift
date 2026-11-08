import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Potenze di 10 rappresentabili esattamente in un Double.
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
    private let base: UnsafePointer<UInt8>
    private let byteCount: Int
    private let lineOffsets: [Int]
    private let quoteByte: UInt8
    private let delimiterByte: UInt8

    /// Esito dell'annusata: il file contiene almeno una virgoletta.
    /// Se è falso né l'indice né `splitFields` devono tracciare lo stato delle quote.
    private let hasQuotes: Bool
    public private(set) var columnNames: [String] = []
    
    private var columnIndexByName: [String: Int] = [:]
    
    public init(fileURL: URL, config: CSVReaderConfig = .init()) throws(CSVErrors) {
        guard let quoteByte = config.quoteCharacter.asciiValue,
              let delimiterByte = config.delimiter.asciiValue else {
            throw CSVErrors.invalidConfiguration
        }
        
        self.quoteByte = quoteByte
        self.delimiterByte = delimiterByte
        
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw CSVErrors.fileIOError(POSIXError(.ENOENT))
        }
        
        defer {
            close(fd)
        }
        
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw CSVErrors.fileIOError(POSIXError(.EIO))
        }
        
        let size = Int(info.st_size)
        guard size > 0 else {
            throw CSVErrors.malformedFile
        }
        
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            throw CSVErrors.fileIOError(POSIXError(.EIO))
        }
        
        let base = UnsafePointer(mapped.assumingMemoryBound(to: UInt8.self))
        
        self.fileURL = fileURL
        self.config = config
        self.base = base
        self.byteCount = size
        
        let dataStart = (size >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF) ? 3 : 0

        // L'annusata: se in tutto il file non c'è una virgoletta, nessun campo può
        // essere quotato, quindi né l'indice né la divisione in campi devono
        // tracciare lo stato delle quote.
        let hasQuotes = memchr(base + dataStart, Int32(quoteByte), size - dataStart) != nil
        self.hasQuotes = hasQuotes

        madvise(mapped, size, MADV_SEQUENTIAL)
        self.lineOffsets = Self.indexLines(
            base: base,
            start: dataStart,
            count: size,
            quoteByte: quoteByte,
            delimiterByte: delimiterByte,
            trackQuotes: hasQuotes
        )
        madvise(mapped, size, MADV_NORMAL)
        
        if config.hasHeaders && !lineOffsets.isEmpty {
            var ranges = [Range<Int>](repeating: 0..<0, count: 64)
            let (start, end) = bounds(ofRow: 0)
            let count = splitFieldsGrowing(start: start, end: end, into: &ranges)
            columnNames = ranges.withUnsafeBufferPointer { buf in
                let header = CSVRow(base: base,
                                    fields: UnsafeBufferPointer(rebasing: buf[0..<count]),
                                    quoteByte: quoteByte)
                return (0..<header.count).map { header.field(at: $0) }
            }
            
            columnIndexByName = Dictionary(
                columnNames.enumerated().map { ($1, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    
    public var rowCount: Int {
        max(0, lineOffsets.count - (config.hasHeaders ? 1 : 0))
    }
    
    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), byteCount)
    }
    
    public func columnIndex(_ name: String) -> Int? {
        columnIndexByName[name]
    }

    public func forEachRow(_ body: (CSVRow) -> Void) {
        let firstRow = config.hasHeaders ? 1 : 0
        // Pre-dimensionato sull'header: le righe hanno quasi sempre quel numero di campi.
        var ranges = [Range<Int>](repeating: 0..<0, count: max(columnNames.count, 8))

        for i in firstRow..<lineOffsets.count {
            let (start, end) = bounds(ofRow: i)
            let count = splitFieldsGrowing(start: start, end: end, into: &ranges)

            ranges.withUnsafeBufferPointer { buf in
                body(CSVRow(base: base,
                            fields: UnsafeBufferPointer(rebasing: buf[0..<count]),
                            quoteByte: quoteByte))
            }
        }
    }
    
    private func bounds(ofRow i: Int) -> (start: Int, end: Int) {
        let start = lineOffsets[i]
        var end = i + 1 < lineOffsets.count ? lineOffsets[i + 1] : byteCount
        if end > start && base[end - 1] == 0x0A { end -= 1 }
        if end > start && base[end - 1] == 0x0D { end -= 1 }
        return (start, end)
    }
    
    /// Divide la riga ingrandendo il buffer se una riga anomala ha più campi del previsto.
    private func splitFieldsGrowing(
        start: Int, end: Int, into ranges: inout [Range<Int>]
    ) -> Int {
        while true {
            if let n = ranges.withUnsafeMutableBufferPointer({
                splitFields(start: start, end: end, into: $0)
            }) {
                return n
            }
            ranges = [Range<Int>](repeating: 0..<0, count: max(ranges.count * 2, 8))
        }
    }

    /// Scrive i campi in `ranges` e restituisce quanti ne ha scritti, oppure `nil`
    /// se il buffer non basta.
    ///
    /// Scrive per indice invece di usare `append`: su milioni di righe da una decina
    /// di campi l'una, il controllo di capacità e unicità COW di ogni `append` diventa
    /// la voce di costo principale.
    private func splitFields(
        start: Int,
        end: Int,
        into ranges: UnsafeMutableBufferPointer<Range<Int>>
    ) -> Int? {
        var n = 0

        // Nessuna virgoletta nel file: i delimitatori sono tutti veri delimitatori,
        // e cercarli con memchr costa meno della macchina a stati.
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
    
    static func indexLines(
        base: UnsafePointer<UInt8>,
        start: Int = 0,
        count: Int,
        quoteByte: UInt8,
        delimiterByte: UInt8,
        trackQuotes: Bool
    ) -> [Int] {
        var offsets: [Int] = [start]
        
       /* guard trackQuotes else {
            for i in 0..<count where base[i] == 0x0A {
                offsets.append(i + 1)
            }
            if offsets.last == count { offsets.removeLast() }
            return offsets
        }*/
        
       guard trackQuotes else {
            var pos = start
            while pos < count,
                  let hit = memchr(base + pos, 0x0A, count - pos) {
                let index = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                offsets.append(index + 1)
                pos = index + 1
            }
            if offsets.last == count { offsets.removeLast() }
            return offsets
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
                    atFieldStart = true
                    fieldIsQuoted = false
                    offsets.append(i + 1)
                }
            }
        }
        
        if offsets.last == count { offsets.removeLast() }
        return offsets
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
        
        // campo normale
        guard quoted else {
            return decode(range)
        }
        
        let inner = (range.lowerBound + 1)..<(range.upperBound - 1)
        
        // campo quotato senza escape
        var hasEscapes = false
        for i in inner where base[i] == quoteByte {
            hasEscapes = true
            break
        }
        
        // campo quotato con escape
        guard hasEscapes else {
            return decode(inner)
        }
        
        var bytes = [UInt8]()
        bytes.reserveCapacity(inner.count)
        var i = inner.lowerBound
        while i < inner.upperBound {
            let b = base[i]
            bytes.append(b)
            i += (b == quoteByte) ? 2 : 1 // di `""` ne tieni una sola
        }
        
        return String(decoding: bytes, as: UTF8.self)
    }
    
    public func boolField(at index: Int) -> Bool? {
        let range = unquotedRange(at: index)

        guard !range.isEmpty, range.count <= 5 else { return nil }

        // Dieci token ASCII da 1-5 byte: la lunghezza sceglie l'unico candidato.
        // `| 0x20` porta le lettere in minuscolo; le cifre vanno confrontate esatte,
        // perché anche `0x11 | 0x20` darebbe '1'.
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
        if base[i] == 0x2D { // segno -
            negative = true
            i += 1
        } else if base[i] == 0x2B {
            i += 1 // sengo +
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

    /// Il range del campo senza le virgolette esterne, se presenti.
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

    /// Stesso risultato di `Double(String)`, bit per bit, senza costruire la stringa.
    ///
    /// Se le cifre stanno entro 2^53 e la potenza di 10 entro 10^22, entrambi i numeri
    /// sono esatti in un Double e una sola divisione IEEE arrotonda correttamente
    /// (metodo di Clinger). Tutto il resto passa dalla libreria standard.
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
                return Double(decode(range)) // esponente, inf, nan, testo
            }
            i += 1
        }

        // "1." e ".5" li decide la libreria standard, così il comportamento resta identico.
        guard integerDigits > 0, !sawPoint || fractionDigits > 0, fractionDigits <= 22 else {
            return Double(decode(range))
        }

        let value = Double(mantissa) / exactPowersOfTen[fractionDigits]
        return negative ? -value : value
    }

    /// Un orario `H:MM:SS` in secondi. Le ore possono superare 24, come nel GTFS,
    /// dove `25:30:00` è l'1:30 di notte del giorno di servizio.
    /// Accetta da 1 a 4 cifre per le ore; minuti e secondi devono stare sotto 60.
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
