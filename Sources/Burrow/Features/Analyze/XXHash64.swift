import Foundation

/// XXH64 (seed 0 by default), bit-for-bit compatible with `cespare/xxhash/v2`, which Mole's
/// analyzer uses to name its cache files. Verified against the reference vectors:
/// XXH64("") = 0xEF46DB3751D8E999, XXH64("a") = 0xD24EC4F1A98C6E5B, XXH64("abc") = 0x44BC2CF5AD770999.
enum XXHash64 {
    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    static func hash(_ string: String, seed: UInt64 = 0) -> UInt64 {
        hash(Array(string.utf8), seed: seed)
    }

    static func hash(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        bytes.withUnsafeBufferPointer { hash($0, seed: seed) }
    }

    static func hash(_ input: UnsafeBufferPointer<UInt8>, seed: UInt64 = 0) -> UInt64 {
        let count = input.count
        var offset = 0
        var h: UInt64

        if count >= 32 {
            var v1 = seed &+ p1 &+ p2
            var v2 = seed &+ p2
            var v3 = seed
            var v4 = seed &- p1
            while offset + 32 <= count {
                v1 = round(v1, read64(input, offset))
                v2 = round(v2, read64(input, offset + 8))
                v3 = round(v3, read64(input, offset + 16))
                v4 = round(v4, read64(input, offset + 24))
                offset += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = mergeRound(h, v1)
            h = mergeRound(h, v2)
            h = mergeRound(h, v3)
            h = mergeRound(h, v4)
        } else {
            h = seed &+ p5
        }

        h = h &+ UInt64(count)

        while offset + 8 <= count {
            let k1 = round(0, read64(input, offset))
            h ^= k1
            h = rotl(h, 27) &* p1 &+ p4
            offset += 8
        }
        if offset + 4 <= count {
            h ^= UInt64(read32(input, offset)) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            offset += 4
        }
        while offset < count {
            h ^= UInt64(input[offset]) &* p5
            h = rotl(h, 11) &* p1
            offset += 1
        }

        h ^= h >> 33
        h = h &* p2
        h ^= h >> 29
        h = h &* p3
        h ^= h >> 32
        return h
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) private static func mergeRound(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        (acc ^ round(0, value)) &* p1 &+ p4
    }

    @inline(__always) private static func read64(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for b in 0..<8 { v |= UInt64(p[i + b]) << (8 * UInt64(b)) }
        return v
    }

    @inline(__always) private static func read32(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt32 {
        var v: UInt32 = 0
        for b in 0..<4 { v |= UInt32(p[i + b]) << (8 * UInt32(b)) }
        return v
    }
}
