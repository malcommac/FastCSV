import Foundation

// MARK: - Supporto su CSVRow

extension CSVRow {
    /// Vero se il campo non contiene nulla, virgolette escluse.
    /// Esiste per non costruire una `String` solo per scoprire che è vuota.
    public func isFieldEmpty(at index: Int) -> Bool {
        unquotedRange(at: index).isEmpty
    }
}

// MARK: - API pubblica

extension CSVReader {
    /// Decodifica ogni riga nel tipo indicato.
    ///
    /// Più lento di `forEachRow` con gli accessori tipizzati: ogni proprietà
    /// costa un hash di stringa per risolvere la colonna, e quella ricerca la
    /// fa il codice generato dal compilatore, quindi non è sollevabile fuori dal ciclo.
    /// Per i file grandi resta preferibile `forEachRow`.
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

// MARK: - Decoder di riga

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
            debugDescription: "Una riga CSV è un insieme di colonne con nome, non un array"))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(
            codingPath: codingPath,
            debugDescription: "Una riga CSV non è un valore singolo"))
    }
}

// MARK: - Container per chiave

struct CSVKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: CSVRow
    let columnIndex: [String: Int]
    var codingPath: [CodingKey]

    var allKeys: [Key] { columnIndex.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool {
        guard let i = columnIndex[key.stringValue] else { return false }
        return i < row.count
    }

    /// Colonna assente e riga corta sono due errori diversi, e conviene distinguerli:
    /// il primo dice che il tipo non corrisponde al file, il secondo quale riga è sporca.
    private func index(for key: Key) throws -> Int {
        guard let i = columnIndex[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath,
                debugDescription: "Nessuna colonna '\(key.stringValue)' nell'header"))
        }
        guard i < row.count else {
            throw DecodingError.valueNotFound(Any.self, .init(
                codingPath: codingPath + [key],
                debugDescription: "La riga ha \(row.count) campi, serviva l'indice \(i)"))
        }
        return i
    }

    private func corrupted(_ key: Key, _ type: Any.Type, _ i: Int) -> DecodingError {
        DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [key],
            debugDescription: "'\(row.field(at: i))' non è un \(type)"))
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

    /// Gli interi stretti passano tutti da qui: `T(exactly:)` rifiuta i fuori intervallo
    /// invece di troncarli, quindi un Int8 che riceve 300 dà errore e non 44.
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

    /// Tutto ciò che non è primitivo (enum con raw value, tipi custom) viene
    /// decodificato da un decoder che vede solo quel campo.
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let i = try index(for: key)
        return try T(from: CSVFieldDecoder(row: row, index: i, codingPath: codingPath + [key]))
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.typeMismatch([String: Any].self, .init(
            codingPath: codingPath + [key],
            debugDescription: "Un CSV è piatto: nessun contenitore annidato"))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(
            codingPath: codingPath + [key],
            debugDescription: "Un CSV è piatto: nessun array annidato"))
    }

    func superDecoder() throws -> Decoder {
        CSVRowDecoder(row: row, columnIndex: columnIndex, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        CSVRowDecoder(row: row, columnIndex: columnIndex, codingPath: codingPath + [key])
    }
}

// MARK: - Decoder di singolo campo

struct CSVFieldDecoder: Decoder {
    let row: CSVRow
    let index: Int
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw DecodingError.typeMismatch([String: Any].self, .init(
            codingPath: codingPath,
            debugDescription: "Un campo CSV è un valore singolo, non un oggetto"))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(
            codingPath: codingPath,
            debugDescription: "Un campo CSV è un valore singolo, non un array"))
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
            debugDescription: "'\(row.field(at: index))' non è un \(type)"))
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
