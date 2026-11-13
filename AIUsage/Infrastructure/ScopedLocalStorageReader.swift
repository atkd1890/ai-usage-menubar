import Foundation

/// Read-only LevelDB decoding. Only the requested Local Storage keys are decoded as strings.
/// Other origins' values remain opaque bytes; no browser/app DB is opened for writing.
struct ScopedLocalStorageReader {
    struct Entry { let sequence: UInt64; let value: Data? }
    enum ReadError: Error { case malformed, unsupported, tooLarge }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0x82f63b78 : 0) }
        return value
    }
    static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data { value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 255)] }
        value = ~value
        return ((value >> 15) | (value << 17)) &+ 0xa282ead8
    }
    static func varint(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw ReadError.malformed }
            let byte = data[offset]; offset += 1
            if shift == 63 && byte > 1 { throw ReadError.malformed }
            value |= UInt64(byte & 127) << shift
            if byte < 128 { return value }
        }
        throw ReadError.malformed
    }
    static func little(_ data: Data, _ offset: Int, _ length: Int) throws -> UInt64 {
        guard offset >= 0, offset + length <= data.count else { throw ReadError.malformed }
        return (0..<length).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }
    static func slice(_ data: Data, _ offset: inout Int, _ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw ReadError.malformed }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    static func snappy(_ data: Data) throws -> Data {
        var p = 0
        let length = try varint(data, &p)
        guard length <= 32 * 1024 * 1024 else { throw ReadError.tooLarge }
        var out = Data(); out.reserveCapacity(Int(length))
        while p < data.count && out.count < length {
            let tag = data[p]; p += 1
            let type = tag & 3
            if type == 0 {
                var n = Int(tag >> 2)
                if n >= 60 {
                    let bytes = n - 59
                    n = Int(try little(data, p, bytes)); p += bytes
                }
                n += 1
                guard n <= Int(length) - out.count else { throw ReadError.malformed }
                out.append(try slice(data, &p, n))
            } else {
                let n: Int; let back: Int
                if type == 1 {
                    guard p < data.count else { throw ReadError.malformed }
                    n = 4 + Int((tag >> 2) & 7)
                    back = Int(tag & 224) << 3 | Int(data[p]); p += 1
                } else {
                    n = 1 + Int(tag >> 2)
                    let bytes = type == 2 ? 2 : 4
                    back = Int(try little(data, p, bytes)); p += bytes
                }
                guard back > 0, back <= out.count, n <= Int(length) - out.count else { throw ReadError.malformed }
                for _ in 0..<n { out.append(out[out.count - back]) }
            }
        }
        guard out.count == length, p == data.count else { throw ReadError.malformed }
        return out
    }
    static func block(_ data: Data, offset: UInt64, size: UInt64) throws -> Data {
        guard offset <= data.count, size <= 32 * 1024 * 1024,
              size + 5 <= UInt64(data.count) - offset else { throw ReadError.malformed }
        var p = Int(offset)
        let raw = try slice(data, &p, Int(size))
        var checked = raw; checked.append(data[p])
        guard UInt64(crc(checked)) == (try little(data, p + 1, 4)) else { throw ReadError.malformed }
        switch data[p] {
        case 0: return raw
        case 1: return try snappy(raw)
        default: throw ReadError.unsupported
        }
    }
    static func pairs(_ block: Data, visit: (Data, Data) throws -> Void) throws {
        guard block.count >= 4 else { throw ReadError.malformed }
        let restarts = try little(block, block.count - 4, 4)
        guard restarts <= UInt64((block.count - 4) / 4) else { throw ReadError.malformed }
        let end = block.count - 4 - Int(restarts) * 4
        var p = 0; var previous = Data()
        while p < end {
            let shared = try varint(block, &p), added = try varint(block, &p), valueLength = try varint(block, &p)
            guard shared <= previous.count, added <= end, valueLength <= end else { throw ReadError.malformed }
            var key = Data(previous.prefix(Int(shared)))
            key.append(try slice(block, &p, Int(added)))
            let value = try slice(block, &p, Int(valueLength))
            guard p <= end else { throw ReadError.malformed }
            try visit(key, value); previous = key
        }
        guard p == end else { throw ReadError.malformed }
    }
    static func table(_ data: Data, visit: (Data, Data) throws -> Void) throws {
        guard data.count >= 48, try little(data, data.count - 8, 8) == 0xdb4775248b80fb57 else { throw ReadError.malformed }
        var p = data.count - 48
        _ = try varint(data, &p); _ = try varint(data, &p)
        let offset = try varint(data, &p), size = try varint(data, &p)
        try pairs(block(data, offset: offset, size: size)) { _, handle in
            var h = 0
            let offset = try varint(handle, &h), size = try varint(handle, &h)
            try pairs(block(data, offset: offset, size: size), visit: visit)
        }
    }
    static func log(_ data: Data, visit: (UInt64, Data, Data?) throws -> Void) throws {
        func batch(_ record: Data) throws {
            guard record.count >= 12 else { throw ReadError.malformed }
            let sequence = try little(record, 0, 8), count = try little(record, 8, 4)
            guard count <= record.count else { throw ReadError.malformed }
            var q = 12
            for i in 0..<count {
                guard q < record.count else { throw ReadError.malformed }
                let type = record[q]; q += 1
                guard type == 0 || type == 1 else { throw ReadError.malformed }
                let keyLength = try varint(record, &q)
                guard keyLength <= record.count else { throw ReadError.malformed }
                let key = try slice(record, &q, Int(keyLength))
                var value: Data?
                if type == 1 {
                    let n = try varint(record, &q)
                    guard n <= record.count else { throw ReadError.malformed }
                    value = try slice(record, &q, Int(n))
                }
                try visit(sequence + i, key, value)
            }
            guard q == record.count else { throw ReadError.malformed }
        }
        try records(data, visit: batch)
    }
    static func records(_ data: Data, visit: (Data) throws -> Void) throws {
        var p = 0; var fragment = Data(); var assembling = false
        while p + 7 <= data.count {
            let remaining = 32768 - p % 32768
            if remaining < 7 { p += remaining; continue }
            let checksum = try little(data, p, 4)
            let length = Int(try little(data, p + 4, 2)), type = data[p + 6]; p += 7
            if type == 0 && length == 0 { p += remaining - 7; continue }
            // A concurrently appended trailing record is not committed yet.
            if p + length > data.count { break }
            guard length <= remaining - 7 else { throw ReadError.malformed }
            let part = try slice(data, &p, length)
            var checked = Data([type]); checked.append(part)
            guard UInt64(crc(checked)) == checksum else { throw ReadError.malformed }
            switch type {
            case 1: try visit(part); fragment = Data(); assembling = false
            case 2: fragment = part; assembling = true
            case 3, 4:
                guard assembling, fragment.count + part.count <= 32 * 1024 * 1024 else { throw ReadError.malformed }
                fragment.append(part)
                if type == 4 { try visit(fragment); fragment = Data(); assembling = false }
            default: throw ReadError.malformed
            }
        }
    }
    func read(directory: URL, origin: String, names: Set<String>) throws -> [String: String] {
        let fm = FileManager.default
        let current = try String(contentsOf: directory.appendingPathComponent("CURRENT"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.hasPrefix("MANIFEST-"), !current.contains("/"), !current.contains("..") else { throw ReadError.malformed }
        let manifestURL = directory.appendingPathComponent(current)
        guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { throw ReadError.tooLarge }
        var tables = Set<UInt64>(); var logNumber: UInt64?; var previousLog: UInt64 = 0
        try Self.records(Data(contentsOf: manifestURL)) { edit in
            var p = 0
            func field() throws { let n = try Self.varint(edit, &p); guard n <= edit.count else { throw ReadError.malformed }; _ = try Self.slice(edit, &p, Int(n)) }
            while p < edit.count {
                switch try Self.varint(edit, &p) {
                case 1: try field()
                case 2: logNumber = try Self.varint(edit, &p)
                case 3, 4: _ = try Self.varint(edit, &p)
                case 5: _ = try Self.varint(edit, &p); try field()
                case 6: _ = try Self.varint(edit, &p); tables.remove(try Self.varint(edit, &p))
                case 7:
                    _ = try Self.varint(edit, &p); tables.insert(try Self.varint(edit, &p))
                    _ = try Self.varint(edit, &p); try field(); try field()
                case 9: previousLog = try Self.varint(edit, &p)
                default: throw ReadError.unsupported
                }
            }
        }
        guard let logNumber else { throw ReadError.malformed }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter {
                guard let number = UInt64($0.deletingPathExtension().lastPathComponent) else { return false }
                return $0.pathExtension == "log" ? (number >= logNumber || number == previousLog) : (["ldb", "sst"].contains($0.pathExtension) && tables.contains(number))
            }
        let prefix = Data(("_" + origin + "\0").utf8)
        var latest: [String: Entry] = [:]; var bytes = 0
        func decode(_ data: Data) -> String? {
            guard let encoding = data.first, encoding == 0 || encoding == 1 else { return nil }
            return String(data: Data(data.dropFirst()), encoding: encoding == 0 ? .utf16LittleEndian : .isoLatin1)
        }
        func accept(_ sequence: UInt64, _ key: Data, _ value: Data?) {
            guard key.starts(with: prefix), let name = decode(Data(key.dropFirst(prefix.count))), names.contains(name) else { return }
            if latest[name].map({ $0.sequence <= sequence }) ?? true { latest[name] = Entry(sequence: sequence, value: value) }
        }
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            bytes += size
            guard size <= 32 * 1024 * 1024, bytes <= 128 * 1024 * 1024 else { throw ReadError.tooLarge }
            let data = try Data(contentsOf: file)
            if file.pathExtension == "log" { try Self.log(data, visit: accept) }
            else {
                try Self.table(data) { key, value in
                    guard key.count >= 8 else { throw ReadError.malformed }
                    let tag = try Self.little(key, key.count - 8, 8)
                    guard tag & 255 <= 1 else { throw ReadError.unsupported }
                    accept(tag >> 8, Data(key.dropLast(8)), tag & 255 == 0 ? nil : value)
                }
            }
        }
        return latest.compactMapValues { $0.value.flatMap(decode) }
    }
}
