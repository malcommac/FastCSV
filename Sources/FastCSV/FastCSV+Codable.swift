import Foundation

// MARK: - CSVRow support

extension CSVRow {
    /// True if the field holds nothing, quotes excluded.
    /// Exists to avoid building a `String` just to find out it is empty.
    public func isFieldEmpty(at index: Int) -> Bool {
        unquotedRange(at: index).isEmpty
    }
}

// MARK: - Public API

extension CSVReader {
    /// Decodes every row into the given type.
    ///
    /// Slower than `forEachRow` with the typed accessors: each property costs a
    /// string hash to resolve its column, and that lookup happens in
    /// compiler-generated code, so it cannot be hoisted out of the loop.
    /// For large files, prefer `forEachRow`.
    public func decode<T: Decodable>(_ type: T.Type, _ body: (T) throws -> Void) throws {
        let columnIndex = Dictionary(
            columnNames.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var failure: Error?

        forEachRow { row in
            guard failure == nil else { return }
            do {
                let decoder = CSVRowDecoder(row: row, columnIndex: columnIndex)
                try body(T(from: decoder))
            } catch {
                failure = error
            }
        }

        if let failure { throw failure }
    }
}

// MARK: - Row decoder

struct CSVRowDecoder: Decoder {
    let row: CSVRow
    let columnIndex: [String: Int]
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(
            CSVKeyedContainer<Key>(row: row, columnIndex: columnIndex, codingPath: codingPath)
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(
            codingPath: codingPath,
            debugDescription: "A CSV row is a set of named columns, not an array"))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(
            codingPath: codingPath,
            debugDescription: "A CSV row is not a single value"))
    }
}

// MARK: - Keyed container

struct CSVKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: CSVRow
    let columnIndex: [String: Int]
    var codingPath: [CodingKey]

    var allKeys: [Key] { columnIndex.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool {
        guard let i = columnIndex[key.stringValue] else { return false }
        return i < row.count
    }

    /// A missing column and a short row are different errors, worth telling apart:
    /// the first says the type doesn't match the file, the second which row is dirty.
    private func index(for key: Key) throws -> Int {
        guard let i = columnIndex[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath,
                debugDescription: "No column '\(key.stringValue)' in the header"))
        }
        guard i < row.count else {
            throw DecodingError.valueNotFound(Any.self, .init(
                codingPath: codingPath + [key],
                debugDescription: "The row has \(row.count) fields, index \(i) was needed"))
        }
        return i
    }

    private func corrupted(_ key: Key, _ type: Any.Type, _ i: Int) -> DecodingError {
        DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "'\(row.field(at: i))' is not a \(type)"))
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        row.isFieldEmpty(at: try index(for: key))
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        row.field(at: try index(for: key))
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let i = try index(for: key)
        guard let v = row.boolField(at: i) else { throw corrupted(key, type, i) }
        return v
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let i = try index(for: key)
        guard let v = row.doubleField(at: i) else { throw corrupted(key, type, i) }
        return v
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        Float(try decode(Double.self, forKey: key))
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        let i = try index(for: key)
        guard let v = row.intField(at: i) else { throw corrupted(key, type, i) }
        return v
    }

    /// All narrow integers go through here: `T(exactly:)` rejects out-of-range values
    /// instead of truncating them, so an Int8 receiving 300 fails rather than becoming 44.
    private func narrow<T: FixedWidthInteger>(_ key: Key, _ type: T.Type) throws -> T {
        let i = try index(for: key)
        guard let wide = row.intField(at: i), let v = T(exactly: wide) else {
            throw corrupted(key, type, i)
        }
        return v
    }

    func decode(_ t: Int8.Type, forKey k: Key) throws -> Int8 { try narrow(k, t) }
    func decode(_ t: Int16.Type, forKey k: Key) throws -> Int16 { try narrow(k, t) }
    func decode(_ t: Int32.Type, forKey k: Key) throws -> Int32 { try narrow(k, t) }
    func decode(_ t: Int64.Type, forKey k: Key) throws -> Int64 { try narrow(k, t) }
    func decode(_ t: UInt.Type, forKey k: Key) throws -> UInt { try narrow(k, t) }
    func decode(_ t: UInt8.Type, forKey k: Key) throws -> UInt8 { try narrow(k, t) }
    func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16 { try narrow(k, t) }
    func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32 { try narrow(k, t) }
    func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64 { try narrow(k, t) }

    /// Anything non-primitive (raw-value enums, custom types) is decoded
    /// by a decoder that sees only that field.
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let i = try index(for: key)
        return try T(from: CSVFieldDecoder(row: row, index: i, codingPath: codingPath + [key]))
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.typeMismatch([String: Any].self, .init(
            codingPath: codingPath + [key],
            debugDescription: "CSV is flat: no nested containers"))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(
            codingPath: codingPath + [key],
            debugDescription: "CSV is flat: no nested arrays"))
    }

    func superDecoder() throws -> Decoder {
        CSVRowDecoder(row: row, columnIndex: columnIndex, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        CSVRowDecoder(row: row, columnIndex: columnIndex, codingPath: codingPath + [key])
    }
}

// MARK: - Single-field decoder

struct CSVFieldDecoder: Decoder {
    let row: CSVRow
    let index: Int
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw DecodingError.typeMismatch([String: Any].self, .init(
            codingPath: codingPath,
            debugDescription: "A CSV field is a single value, not an object"))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(
            codingPath: codingPath,
            debugDescription: "A CSV field is a single value, not an array"))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        CSVSingleValueContainer(row: row, index: index, codingPath: codingPath)
    }
}

struct CSVSingleValueContainer: SingleValueDecodingContainer {
    let row: CSVRow
    let index: Int
    var codingPath: [CodingKey]

    private func corrupted(_ type: Any.Type) -> DecodingError {
        DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "'\(row.field(at: index))' is not a \(type)"))
    }

    func decodeNil() -> Bool {
        row.isFieldEmpty(at: index)
    }

    func decode(_ type: String.Type) throws -> String {
        row.field(at: index)
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard let v = row.boolField(at: index) else { throw corrupted(type) }
        return v
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard let v = row.doubleField(at: index) else { throw corrupted(type) }
        return v
    }

    func decode(_ type: Float.Type) throws -> Float {
        Float(try decode(Double.self))
    }

    func decode(_ type: Int.Type) throws -> Int {
        guard let v = row.intField(at: index) else { throw corrupted(type) }
        return v
    }

    private func narrow<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let wide = row.intField(at: index), let v = T(exactly: wide) else {
            throw corrupted(type)
        }
        return v
    }

    func decode(_ t: Int8.Type) throws -> Int8 { try narrow(t) }
    func decode(_ t: Int16.Type) throws -> Int16 { try narrow(t) }
    func decode(_ t: Int32.Type) throws -> Int32 { try narrow(t) }
    func decode(_ t: Int64.Type) throws -> Int64 { try narrow(t) }
    func decode(_ t: UInt.Type) throws -> UInt { try narrow(t) }
    func decode(_ t: UInt8.Type) throws -> UInt8 { try narrow(t) }
    func decode(_ t: UInt16.Type) throws -> UInt16 { try narrow(t) }
    func decode(_ t: UInt32.Type) throws -> UInt32 { try narrow(t) }
    func decode(_ t: UInt64.Type) throws -> UInt64 { try narrow(t) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: CSVFieldDecoder(row: row, index: index, codingPath: codingPath))
    }
}
