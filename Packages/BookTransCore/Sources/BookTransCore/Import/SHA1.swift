import Foundation

/// SHA-1, used only to derive stable, collision-resistant file names for images
/// extracted out of EPUB archives (see docs/SPEC.md §8.2.4).
///
/// Implemented here rather than pulled in as a dependency: the project keeps
/// exactly one external package (ZIPFoundation), and CryptoKit's `Insecure.SHA1`
/// does not exist on Linux, where the Core tests run.
public enum SHA1 {
    public static func digest(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xEFCD_AB89
        var h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476
        var h4: UInt32 = 0xC3D2_E1F0

        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var words = [UInt32](repeating: 0, count: 80)
        var chunkStart = 0
        while chunkStart < data.count {
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = (UInt32(data[offset]) << 24)
                    | (UInt32(data[offset + 1]) << 16)
                    | (UInt32(data[offset + 2]) << 8)
                    | UInt32(data[offset + 3])
            }
            for index in 16..<80 {
                let value = words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]
                words[index] = (value << 1) | (value >> 31)
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4
            for index in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch index {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9_EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1B_BCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62_C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ words[index]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            chunkStart += 64
        }

        var out: [UInt8] = []
        out.reserveCapacity(20)
        for value in [h0, h1, h2, h3, h4] {
            out.append(UInt8((value >> 24) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }

    public static func hexDigest(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(40)
        for byte in digest(bytes) {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }

    public static func hexDigest(_ text: String) -> String {
        hexDigest(Array(text.utf8))
    }
}
