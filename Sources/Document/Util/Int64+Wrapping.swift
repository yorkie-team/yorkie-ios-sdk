/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

extension Int64 {
    /// Creates the 64-bit two's complement integer a finite `Double` truncates to, wrapping when it
    /// is out of range instead of trapping.
    ///
    /// This is the Swift counterpart of Go's `TruncFloatToInt64` and of
    /// `BigInt.asIntN(64, BigInt(Math.trunc(f)))` in the JS SDK: `value` is truncated toward zero and
    /// reduced modulo 2^64 into `[-2^63, 2^63)`. A plain `Int64(value)` traps for an out-of-range value,
    /// so every replica must go through here to converge.
    ///
    /// - Precondition: `value` is finite. Callers guard `value.isFinite` first.
    init(wrapping value: Double) {
        precondition(value.isFinite, "a non-finite Double has no integer value")

        let truncated = value.rounded(.towardZero)
        if truncated >= -0x1p63, truncated < 0x1p63 {
            self = Int64(truncated)
            return
        }

        // Out of range: `truncated` is an exact integer, and `truncatingRemainder` is exact.
        var remainder = truncated.truncatingRemainder(dividingBy: 0x1p64)
        if remainder >= 0x1p63 {
            remainder -= 0x1p64
        } else if remainder < -0x1p63 {
            remainder += 0x1p64
        }
        self = Int64(remainder)
    }
}
