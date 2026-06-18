/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

// HyperLogLog precision and register count.
private let hllPrecision = 14
private let hllRegisterCount = 1 << hllPrecision // 16384

// xxhash64 constants (64-bit, matching Go's cespare/xxhash/v2 and JS implementation).
private let prime64x1: UInt64 = 0x9E37_79B1_85EB_CA87
private let prime64x2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
private let prime64x3: UInt64 = 0x1656_67B1_9E37_79F9
private let prime64x4: UInt64 = 0x85EB_CA77_C2B2_AE63
private let prime64x5: UInt64 = 0x27D4_EB2F_1656_67C5

/**
 * `HLL` is a HyperLogLog implementation used for approximate cardinality
 * estimation in Counter dedup mode. It uses xxhash64 hashing (matching the
 * Go server) and precision 14 (16384 registers, ~16KB, ~2% error).
 */
class HLL {
    private var registers: [UInt8]

    init() {
        self.registers = [UInt8](repeating: 0, count: hllRegisterCount)
    }

    /// Adds a value to the HLL and returns true if the register was updated.
    @discardableResult
    func add(value: String) -> Bool {
        let hash = xxhash64(input: value)
        let idx = Int(hash >> UInt64(64 - hllPrecision))
        // Shift the hash left by precision bits to get the remaining bits,
        // then OR in a sentinel 1 at bit (precision-1) so countLeadingZeros64
        // terminates correctly even when all remaining bits are zero.
        let remaining = (hash &<< UInt64(hllPrecision)) | (1 << UInt64(hllPrecision - 1))
        let rho = countLeadingZeros64(remaining) + 1
        if rho > self.registers[idx] {
            self.registers[idx] = rho
            return true
        }
        return false
    }

    /// Returns the approximate cardinality estimate.
    func count() -> Int {
        let registerCount = hllRegisterCount
        let alpha = 0.7213 / (1.0 + 1.079 / Double(registerCount))
        var sum = 0.0
        var zeros = 0
        for idx in 0 ..< registerCount {
            sum += pow(2.0, -Double(self.registers[idx]))
            if self.registers[idx] == 0 { zeros += 1 }
        }
        var estimate = (alpha * Double(registerCount) * Double(registerCount)) / sum
        if estimate <= 2.5 * Double(registerCount), zeros > 0 {
            estimate = Double(registerCount) * log(Double(registerCount) / Double(zeros))
        }
        return Int(estimate.rounded())
    }

    /// Merges another HLL into this one by taking the max of each register.
    ///
    /// This operation is commutative, associative, and idempotent.
    func merge(_ other: HLL) {
        for idx in 0 ..< hllRegisterCount where other.registers[idx] > self.registers[idx] {
            self.registers[idx] = other.registers[idx]
        }
    }

    /// Serializes the HLL registers to a byte array.
    func toBytes() -> [UInt8] {
        return self.registers
    }

    /// Restores the HLL registers from a byte array.
    ///
    /// - Parameter data: The byte array to restore from.
    /// - Throws: ``YorkieError`` with code ``YorkieErrorCode/errInvalidArgument``
    ///   when the data length does not match the register count.
    func restore(_ data: [UInt8]) throws {
        guard data.count == hllRegisterCount else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "invalid HLL register payload: got \(data.count) bytes, want \(hllRegisterCount)"
            )
        }
        self.registers = data
    }
}

// MARK: - xxhash64

/// Computes a 64-bit xxHash of the given string with seed 0.
///
/// Produces identical output to Go's cespare/xxhash/v2.
/// All multi-byte reads are little-endian, matching the JS reference implementation.
private func xxhash64(input: String) -> UInt64 {
    let buf = Array(input.utf8)
    let len = buf.count
    var h64: UInt64
    var offset = 0

    if len >= 32 {
        var v1: UInt64 = 0 &+ prime64x1 &+ prime64x2
        var v2: UInt64 = 0 &+ prime64x2
        var v3: UInt64 = 0
        var v4: UInt64 = 0 &- prime64x1

        while offset <= len - 32 {
            v1 = xxRound(v1, readU64LE(buf, offset)); offset += 8
            v2 = xxRound(v2, readU64LE(buf, offset)); offset += 8
            v3 = xxRound(v3, readU64LE(buf, offset)); offset += 8
            v4 = xxRound(v4, readU64LE(buf, offset)); offset += 8
        }

        h64 = rotl64(v1, 1) &+ rotl64(v2, 7) &+ rotl64(v3, 12) &+ rotl64(v4, 18)
        h64 = xxMergeRound(h64, v1)
        h64 = xxMergeRound(h64, v2)
        h64 = xxMergeRound(h64, v3)
        h64 = xxMergeRound(h64, v4)
    } else {
        h64 = 0 &+ prime64x5
    }

    h64 = h64 &+ UInt64(len)

    while offset + 8 <= len {
        let k1 = xxRound(0, readU64LE(buf, offset))
        h64 = rotl64(h64 ^ k1, 27) &* prime64x1 &+ prime64x4
        offset += 8
    }

    if offset + 4 <= len {
        h64 = h64 ^ (UInt64(readU32LE(buf, offset)) &* prime64x1)
        h64 = rotl64(h64, 23) &* prime64x2 &+ prime64x3
        offset += 4
    }

    while offset < len {
        h64 = h64 ^ (UInt64(buf[offset]) &* prime64x5)
        h64 = rotl64(h64, 11) &* prime64x1
        offset += 1
    }

    h64 = (h64 ^ (h64 >> 33)) &* prime64x2
    h64 = (h64 ^ (h64 >> 29)) &* prime64x3
    h64 = h64 ^ (h64 >> 32)

    return h64
}

/// Rotates a 64-bit value left by `shift` bits.
private func rotl64(_ value: UInt64, _ shift: UInt64) -> UInt64 {
    return (value &<< shift) | (value >> (64 - shift))
}

/// Performs a single xxhash64 accumulator round.
private func xxRound(_ acc: UInt64, _ input: UInt64) -> UInt64 {
    var accum = acc
    accum = accum &+ (input &* prime64x2)
    accum = rotl64(accum, 31)
    return accum &* prime64x1
}

/// Merges an accumulator lane into the final hash.
private func xxMergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
    let rounded = xxRound(0, val)
    var accum = acc ^ rounded
    return accum &* prime64x1 &+ prime64x4
}

/// Reads a little-endian 64-bit unsigned integer from `buf` starting at `offset`.
private func readU64LE(_ buf: [UInt8], _ offset: Int) -> UInt64 {
    // Read bytes from highest to lowest index, shifting left 8 bits each step —
    // this matches the JS `for (let i = 7; i >= 0; i--) { val = (val << 8n) | buf[offset+i] }`.
    var val: UInt64 = 0
    for byteIdx in stride(from: 7, through: 0, by: -1) {
        val = (val << 8) | UInt64(buf[offset + byteIdx])
    }
    return val
}

/// Reads a little-endian 32-bit unsigned integer from `buf` starting at `offset`.
private func readU32LE(_ buf: [UInt8], _ offset: Int) -> UInt32 {
    return UInt32(buf[offset])
        | (UInt32(buf[offset + 1]) << 8)
        | (UInt32(buf[offset + 2]) << 16)
        | (UInt32(buf[offset + 3]) << 24)
}

/// Counts the number of leading zero bits in a 64-bit unsigned integer.
///
/// Returns 64 when `value` is zero, mirroring the JS implementation.
private func countLeadingZeros64(_ value: UInt64) -> UInt8 {
    if value == 0 { return 64 }
    return UInt8(value.leadingZeroBitCount)
}
