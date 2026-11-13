import Foundation

/// The small protobuf subset used by Gemini's local auth and read-only quota RPC.
enum GeminiProtobuf {
    enum DecodeError: Error { case malformed }
    struct Field: Sendable {
        let number: Int
        var integer: UInt64? = nil
        var bytes: Data? = nil
        var floating: Double? = nil
    }
    static func fields(_ data: Data) throws -> [Field] {
        guard data.count <= 4_194_304 else { throw DecodeError.malformed }
        let input = [UInt8](data)
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < input.count else { throw DecodeError.malformed }
                let byte = input[offset]; offset += 1
                guard shift < 63 || byte <= 1 else { throw DecodeError.malformed }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw DecodeError.malformed
        }
        var result: [Field] = []
        while offset < input.count {
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw DecodeError.malformed }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                result.append(Field(number: number, integer: try varint()))
            case 2:
                let length = try varint()
                guard length <= UInt64(input.count - offset) else { throw DecodeError.malformed }
                let end = offset + Int(length)
                result.append(Field(number: number, bytes: Data(input[offset..<end])))
                offset = end
            case 1, 5:
                let length = tag & 7 == 1 ? 8 : 4
                guard input.count - offset >= length else { throw DecodeError.malformed }
                var bits: UInt64 = 0
                for index in 0..<length { bits |= UInt64(input[offset + index]) << (index * 8) }
                let value = length == 8 ? Double(bitPattern: bits) : Double(Float(bitPattern: UInt32(bits)))
                result.append(Field(number: number, floating: value))
                offset += length
            default: throw DecodeError.malformed
            }
        }
        return result
    }
    static func hexData(_ text: String) throws -> Data {
        guard !text.isEmpty, text.count <= 8_388_608, text.count % 2 == 0 else { throw DecodeError.malformed }
        var data = Data(); var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<end], radix: 16) else { throw DecodeError.malformed }
            data.append(byte); index = end
        }
        return data
    }
}
