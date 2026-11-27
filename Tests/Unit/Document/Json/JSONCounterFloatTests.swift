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

import XCTest
@testable import Yorkie

/// `JSONCounter.increase(value:)` with a floating-point delta.
///
/// A finite delta is truncated toward zero and wrapped at the counter width, as Go's
/// `json.Counter.Increase` does (`TruncFloatToInt32` / `TruncFloatToInt64`) and as a remote Increase
/// does. A NaN or an infinity is rejected (Go panics, JS throws RangeError); this overload does not
/// throw, so it is logged and ignored. Before, `T(value)` trapped the process for all of them.
@MainActor
final class JSONCounterFloatTests: XCTestCase {
    private let sourceActor = "000000000000000000000001"

    /// Runs one local update that creates a counter holding `initial` and increases it by `delta`.
    private func updated<T: YorkieCountable>(_ initial: T, by delta: any BinaryFloatingPoint) throws -> Document {
        let doc = Document(key: "d")
        doc.setActor(self.sourceActor)
        try doc.update { root, _ in
            root.c = JSONCounter(value: initial)
            (root.c as? JSONCounter<T>)?.increase(value: delta)
        }
        return doc
    }

    private func json(_ doc: Document) -> String {
        doc.toSortedJSON()
    }

    func test_can_ignore_a_nan_counter_float_value() throws {
        // given / when
        let int32Doc = try self.updated(Int32(10), by: Double.nan)
        let floatDoc = try self.updated(Int64(10), by: Float.nan)

        // then - the counter is untouched and no IncreaseOperation was pushed
        XCTAssertEqual(self.json(int32Doc), "{\"c\":10}")
        XCTAssertEqual(self.json(floatDoc), "{\"c\":10}")
        for doc in [int32Doc, floatDoc] {
            let operations = doc.createChangePack().getChanges().flatMap(\.operations)
            XCTAssertFalse(operations.contains { $0 is IncreaseOperation })
        }
    }

    func test_can_ignore_an_infinite_counter_float_value_int32() throws {
        let doc = try self.updated(Int32(10), by: -Double.infinity)

        XCTAssertEqual(self.json(doc), "{\"c\":10}")
        let operations = doc.createChangePack().getChanges().flatMap(\.operations)
        XCTAssertFalse(operations.contains { $0 is IncreaseOperation })
    }

    func test_can_ignore_an_infinite_counter_float_value_int64() throws {
        let doc = try self.updated(Int64(10), by: Double.infinity)

        XCTAssertEqual(self.json(doc), "{\"c\":10}")
        let operations = doc.createChangePack().getChanges().flatMap(\.operations)
        XCTAssertFalse(operations.contains { $0 is IncreaseOperation })
    }

    func test_can_wrap_int32_counter_when_increased_by_out_of_range_float() throws {
        // 1e10 mod 2^32 = 1410065408
        XCTAssertEqual(try self.json(self.updated(Int32(10), by: 1e10)), "{\"c\":1410065418}")
        // just past Int32.max
        XCTAssertEqual(try self.json(self.updated(Int32(10), by: 2_147_483_648.0)), "{\"c\":-2147483638}")
        // just past Int32.min wraps to Int32.max, then the sum wraps again
        XCTAssertEqual(try self.json(self.updated(Int32(10), by: -2_147_483_649.0)), "{\"c\":-2147483639}")
        // a Float widens exactly to Double
        XCTAssertEqual(try self.json(self.updated(Int32(10), by: Float(1e10))), "{\"c\":1410065418}")
    }

    func test_can_wrap_int64_counter_when_increased_by_out_of_range_float() throws {
        XCTAssertEqual(try self.json(self.updated(Int64(10), by: 1e19)), "{\"c\":-8446744073709551606}")
        XCTAssertEqual(try self.json(self.updated(Int64(10), by: -1e19)), "{\"c\":8446744073709551626}")
        XCTAssertEqual(try self.json(self.updated(Int64(10), by: 9_223_372_036_854_775_808.0)), "{\"c\":-9223372036854775798}")
        // 1e300 is a multiple of 2^64, so it wraps to 0
        XCTAssertEqual(try self.json(self.updated(Int64(0), by: 1e300)), "{\"c\":0}")
    }

    func test_can_truncate_a_counter_float_value_toward_zero_at_the_range_edges() throws {
        XCTAssertEqual(try self.json(self.updated(Int32(0), by: 2_147_483_647.9)), "{\"c\":2147483647}")
        XCTAssertEqual(try self.json(self.updated(Int32(0), by: -2_147_483_648.9)), "{\"c\":-2147483648}")
        XCTAssertEqual(try self.json(self.updated(Int64(0), by: 0x1p62)), "{\"c\":4611686018427387904}")
    }

    func test_can_sync_a_wrapped_counter_float_value() throws {
        // given - a local increase that wrapped
        let source = try self.updated(Int32(10), by: 1e10)
        var pbPack = Converter.toChangePack(pack: source.createChangePack())
        pbPack.checkpoint.serverSeq = 1

        // when - a peer applies the pushed change through the remote path
        let change = try XCTUnwrap(Converter.fromChangePack(pbPack).getChanges().first)
        let increase = try XCTUnwrap(change.operations.compactMap { $0 as? IncreaseOperation }.first)
        let target = Document(key: "d")
        try target.applyChangePack(Converter.fromChangePack(pbPack))

        // then - an integer of the counter's width travelled, and both replicas converge
        XCTAssertEqual((increase.value as? Primitive)?.value, .integer(1_410_065_408))
        XCTAssertEqual(self.json(target), self.json(source))
        XCTAssertEqual(self.json(target), "{\"c\":1410065418}")
    }
}
