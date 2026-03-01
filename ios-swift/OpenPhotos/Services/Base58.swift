import Foundation

enum Base58 {
    // Bitcoin alphabet
    private static let alphabet: [Character] = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func encode(_ data: Data) -> String {
        if data.isEmpty { return "" }

        // Count leading zeros
        let bytes = [UInt8](data)
        var zeros = 0
        for b in bytes { if b == 0 { zeros += 1 } else { break } }

        // Convert base-256 digits to base-58 digits (mod/div)
        var input = bytes
        var startAt = zeros
        var encoded: [UInt8] = []

        while startAt < input.count {
            var carry = 0
            for i in startAt..<input.count {
                let val = Int(input[i]) + carry * 256
                input[i] = UInt8(val / 58)
                carry = val % 58
            }
            encoded.append(UInt8(carry))
            while startAt < input.count && input[startAt] == 0 { startAt += 1 }
        }

        // Leading zeros become '1'
        var result = String(repeating: String(alphabet[0]), count: zeros)
        for c in encoded.reversed() {
            result.append(alphabet[Int(c)])
        }
        return result
    }
}

