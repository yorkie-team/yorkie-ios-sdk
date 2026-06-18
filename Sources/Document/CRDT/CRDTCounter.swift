/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

/**
 * `CRDTCounter` represents changeable number data type.
 *
 * When `isDedup` is `true` the counter is a HyperLogLog-backed dedup counter
 * (equivalent to JS `CounterType.IntDedup`). Its `value` is always derived
 * from the HLL cardinality estimate and its type parameter is always `Int32`.
 */
class CRDTCounter<T: YorkieCountable>: CRDTElement {
    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    private(set) var value: T

    /// Whether this counter uses HyperLogLog-based actor deduplication.
    private(set) var isDedup: Bool

    /// HLL state; non-nil exactly when `isDedup == true`.
    private var hll: HLL?

    // MARK: – Initializers

    /// Creates a regular (non-dedup) counter.
    init(value: T, createdAt: TimeTicket) {
        self.createdAt = createdAt
        self.value = value
        self.isDedup = false
        self.hll = nil
    }

    /// Creates a dedup counter.  `T` must be `Int32`; `value` is ignored —
    /// the counter value is always derived from the HLL cardinality.
    ///
    /// - Parameters:
    ///   - dedup: Pass `true` to create a dedup counter.
    ///   - createdAt: Creation timestamp.
    init(dedupWithCreatedAt createdAt: TimeTicket) where T == Int32 {
        self.createdAt = createdAt
        self.value = 0
        self.isDedup = true
        self.hll = HLL()
    }

    // MARK: – CRDTElement

    func toJSON() -> String {
        "\(self.value)"
    }

    func toSortedJSON() -> String {
        self.toJSON()
    }

    func deepcopy() -> CRDTElement {
        if self.isDedup, let counter = self as? CRDTCounter<Int32> {
            let copy = CRDTCounter<Int32>(dedupWithCreatedAt: self.createdAt)
            copy.movedAt = self.movedAt
            copy.removedAt = self.removedAt
            if let bytes = counter.hllBytes() {
                do {
                    try copy.restoreHLL(bytes)
                } catch {
                    // hllBytes() always returns a valid 16384-byte payload, so this
                    // should never happen; log loudly rather than silently dropping
                    // the HLL state and producing an inconsistent copy.
                    Logger.error("failed to restore HLL on deepcopy", error: error)
                }
            }
            return copy
        }

        let counter = CRDTCounter(value: self.value, createdAt: self.createdAt)
        counter.movedAt = self.movedAt
        counter.removedAt = self.removedAt
        return counter
    }

    // MARK: – DataSize

    /// Returns the data usage of this element.
    func getDataSize() -> DataSize {
        var data = self.value is Int32 ? 4 : 8
        if self.isDedup, let hll {
            data += hll.toBytes().count
        }
        return DataSize(data: data, meta: self.getMetaUsage())
    }

    // MARK: – Serialisation

    /// Creates a byte array representing the value (little-endian).
    func toBytes() -> Data {
        return withUnsafeBytes(of: self.value.littleEndian) { Data($0) }
    }

    /// Returns the serialised HLL register bytes, or `nil` when not in dedup mode.
    func hllBytes() -> Data? {
        guard self.isDedup, let hll else { return nil }
        return Data(hll.toBytes())
    }

    // MARK: – Mutations

    /// Increases the counter by the given primitive value.
    ///
    /// - Throws: ``YorkieError`` when called on a dedup counter; use
    ///   ``increaseDedup(_:actor:)`` instead.
    @discardableResult
    func increase(_ primitive: Primitive) throws -> CRDTCounter {
        if self.isDedup {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "dedup counter requires actor, use increaseDedup(_:actor:)"
            )
        }

        switch primitive.value {
        case .integer(let int32Value):
            self.value &+= T(int32Value)
        case .long(let int64Value):
            self.value &+= T(int64Value)
        default:
            throw YorkieError(code: .errUnimplemented, message: "Unsupported type of value: \(type(of: primitive.value))")
        }

        return self
    }

    /// Increases the dedup counter by recording the given actor in the HLL.
    ///
    /// Only the `Int32` specialisation supports dedup. The primitive value
    /// must be 1 (integer or long).
    ///
    /// - Parameters:
    ///   - primitive: The increment value (must be 1).
    ///   - actor: The actor identifier to record in the HLL.
    /// - Throws: ``YorkieError`` when not in dedup mode, when `actor` is
    ///   empty, or when `primitive` is not 1.
    @discardableResult
    func increaseDedup(_ primitive: Primitive, actor: String) throws -> CRDTCounter where T == Int32 {
        guard self.isDedup, let hll else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "increaseDedup called on a non-dedup counter"
            )
        }
        guard !actor.isEmpty else {
            throw YorkieError(code: .errInvalidArgument, message: "dedup counter requires actor")
        }

        // Only increment-by-1 is supported (mirrors JS reference).
        let isUnit: Bool
        switch primitive.value {
        case .integer(let val): isUnit = (val == 1)
        case .long(let val): isUnit = (val == 1)
        default: isUnit = false
        }
        guard isUnit else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "dedup counter only supports increment by 1"
            )
        }

        if hll.add(value: actor) {
            self.value = Int32(hll.count())
        }

        return self
    }

    /// Restores the HLL state from the given serialised bytes and recomputes
    /// the counter value.
    ///
    /// - Parameter data: Serialised register bytes from ``hllBytes()``.
    /// - Throws: ``YorkieError`` when not in dedup mode, or when the byte
    ///   count does not match the expected register count.
    func restoreHLL(_ data: Data) throws where T == Int32 {
        guard self.isDedup else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "restoreHLL called on a non-dedup counter"
            )
        }
        if self.hll == nil { self.hll = HLL() }
        try self.hll!.restore([UInt8](data))
        self.value = Int32(self.hll!.count())
    }
}
