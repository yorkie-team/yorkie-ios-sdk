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

import XCTest
@testable import Yorkie

/// Unit tests for the ``HLL`` HyperLogLog implementation.
///
/// Upstream does not ship a dedicated hll_test.ts; these cases guard the Swift
/// port against regressions introduced during forward-port work.
final class HLLTests: XCTestCase {
    // MARK: - Empty / initial state

    func test_empty_hll_count_is_zero() {
        // given
        let hll = HLL()

        // then
        XCTAssertEqual(hll.count(), 0)
    }

    func test_toBytes_of_empty_hll_is_all_zeros() {
        // given
        let hll = HLL()

        // then
        let bytes = hll.toBytes()
        XCTAssertEqual(bytes.count, 16384, "register count must equal 2^14")
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 }, "all registers must start at 0")
    }

    // MARK: - add returns update flag

    func test_add_returns_true_on_first_insertion() {
        // given
        let hll = HLL()

        // when / then
        XCTAssertTrue(hll.add(value: "actor-a"), "first add for a new value must return true")
    }

    func test_add_returns_false_for_already_seen_value() {
        // given
        let hll = HLL()
        hll.add(value: "actor-a")

        // when / then — same value again must be a no-op
        XCTAssertFalse(hll.add(value: "actor-a"), "duplicate add must return false")
    }

    func test_add_different_values_returns_true() {
        // given
        let hll = HLL()
        hll.add(value: "actor-a")

        // when / then — a genuinely distinct value must return true
        XCTAssertTrue(hll.add(value: "actor-b"), "new distinct value must return true")
    }

    // MARK: - Cardinality estimate

    func test_count_increases_as_distinct_values_are_added() {
        // given
        let hll = HLL()

        // when
        for idx in 0 ..< 10 {
            hll.add(value: "actor-\(idx)")
        }

        // then — HLL guarantees ~2 % error; 10 distinct values should be within ±5
        let estimate = hll.count()
        XCTAssertGreaterThan(estimate, 0)
        XCTAssertLessThanOrEqual(estimate, 15)
    }

    func test_count_does_not_change_on_duplicate_adds() {
        // given
        let hll = HLL()
        hll.add(value: "actor-x")
        let countAfterFirst = hll.count()

        // when — add the same value several more times
        for _ in 0 ..< 5 {
            hll.add(value: "actor-x")
        }

        // then
        XCTAssertEqual(hll.count(), countAfterFirst, "duplicate adds must not change the estimate")
    }

    // MARK: - merge idempotence

    func test_merge_is_idempotent() {
        // given
        let hllA = HLL()
        hllA.add(value: "actor-1")
        hllA.add(value: "actor-2")

        let hllB = HLL()
        hllB.add(value: "actor-1")
        hllB.add(value: "actor-2")

        // when — merge same HLL twice
        hllA.merge(hllB)
        let countAfterFirst = hllA.count()
        hllA.merge(hllB)

        // then
        XCTAssertEqual(hllA.count(), countAfterFirst, "merging the same HLL again must not change the estimate")
    }

    func test_merge_combines_distinct_values() {
        // given
        let hllA = HLL()
        hllA.add(value: "actor-a")

        let hllB = HLL()
        hllB.add(value: "actor-b")

        let countA = hllA.count()
        let countB = hllB.count()

        // when
        hllA.merge(hllB)

        // then — merged cardinality must be at least as large as each individual estimate
        XCTAssertGreaterThanOrEqual(hllA.count(), max(countA, countB))
    }

    func test_merge_is_commutative() {
        // given
        let hllA = HLL()
        hllA.add(value: "actor-1")

        let hllB = HLL()
        hllB.add(value: "actor-2")

        let hllACopy = HLL()
        hllACopy.add(value: "actor-1")

        let hllBCopy = HLL()
        hllBCopy.add(value: "actor-2")

        // when — hllA.merge(hllB) and hllB.merge(hllA) must produce the same count
        hllA.merge(hllB)
        hllBCopy.merge(hllACopy)

        // then
        XCTAssertEqual(hllA.count(), hllBCopy.count(), "merge must be commutative")
    }

    // MARK: - toBytes / restore round-trip

    func test_toBytes_restore_round_trip_preserves_count() throws {
        // given
        let original = HLL()
        for idx in 0 ..< 5 {
            original.add(value: "user-\(idx)")
        }
        let before = original.count()
        let bytes = original.toBytes()

        // when
        let restored = HLL()
        try restored.restore(bytes)

        // then
        XCTAssertEqual(restored.count(), before, "restored HLL must return the same cardinality")
    }

    func test_toBytes_produces_correct_length() {
        // given
        let hll = HLL()
        hll.add(value: "a")

        // when
        let bytes = hll.toBytes()

        // then
        XCTAssertEqual(bytes.count, 16384)
    }

    func test_restore_wrong_length_throws() {
        // given
        let hll = HLL()
        let badBytes: [UInt8] = [0, 1, 2] // too short

        // when / then
        XCTAssertThrowsError(try hll.restore(badBytes)) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError but got \(error)")
                return
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    func test_restore_empty_payload_throws() {
        // given
        let hll = HLL()

        // when / then
        XCTAssertThrowsError(try hll.restore([])) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError but got \(error)")
                return
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    // MARK: - add is stable for known inputs

    func test_add_of_empty_string_returns_true_then_false() {
        // given
        let hll = HLL()

        // when / then — empty string is a valid actor label
        XCTAssertTrue(hll.add(value: ""))
        XCTAssertFalse(hll.add(value: ""))
    }
}
