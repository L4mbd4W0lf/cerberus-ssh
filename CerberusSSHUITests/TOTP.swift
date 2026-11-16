import Foundation
import CryptoKit

/// One-time codes (RFC 6238: HMAC-SHA-1, 6 digits, 30 s), for the test server that asks for one.
enum TOTP {
    /// The code the server will accept now; `step` shifts by whole periods (the server allows a few either way).
    static func code(secret: String, at date: Date = Date(), step: Int = 0) -> String {
        let key = SymmetricKey(data: base32Decode(secret))
        var counter = (UInt64(date.timeIntervalSince1970 / 30) &+ UInt64(bitPattern: Int64(step))).bigEndian
        let mac = withUnsafeBytes(of: &counter) { HMAC<Insecure.SHA1>.authenticationCode(for: Data($0), using: key) }
        let bytes = Array(mac)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        let value = (UInt32(bytes[offset] & 0x7f) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        return String(format: "%06d", value % 1_000_000)
    }

    private static func base32Decode(_ text: String) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, accumulator = 0
        var out = Data()
        for character in text.uppercased() {
            guard let index = alphabet.firstIndex(of: character) else { continue }
            accumulator = (accumulator << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((accumulator >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }
}
