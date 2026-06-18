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

/// Unit tests for ``CRDTCounter`` in dedup mode and ``JSONDedupCounter``.
///
/// Mirrors the new dedup-counter behaviour introduced in yorkie-js-sdk #1215/#1216.
/// Dedup counters count distinct actors — each unique actor ID contributes exactly
/// 1 to the cardinality, and repeated calls with the same actor are no-ops.
final class CRDTDedupCounterTests: XCTestCase {
    // MARK: - Initial state

    func test_dedup_counter_initial_value_is_zero() {
        // given / when
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)

        // then
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(counter.isDedup)
    }

    func test_regular_counter_is_not_dedup() {
        // given / when
        let counter = CRDTCounter(value: Int32(5), createdAt: TimeTicket.initial)

        // then
        XCTAssertFalse(counter.isDedup)
    }

    // MARK: - increaseDedup — basic counting

    func test_increase_dedup_increments_for_new_actor() throws {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)

        // when
        try counter.increaseDedup(primitive, actor: "actor-a")

        // then — one distinct actor → value becomes 1
        XCTAssertEqual(counter.value, 1)
    }

    func test_increase_dedup_same_actor_is_idempotent() throws {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)

        // when — add the same actor multiple times
        try counter.increaseDedup(primitive, actor: "actor-a")
        try counter.increaseDedup(primitive, actor: "actor-a")
        try counter.increaseDedup(primitive, actor: "actor-a")

        // then — still 1 distinct actor
        XCTAssertEqual(counter.value, 1)
    }

    func test_increase_dedup_distinct_actors_count_separately() throws {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)

        // when
        try counter.increaseDedup(primitive, actor: "actor-a")
        try counter.increaseDedup(primitive, actor: "actor-b")
        try counter.increaseDedup(primitive, actor: "actor-c")

        // then — three distinct actors; HLL guarantees ~2 % error, so within ±2
        XCTAssertGreaterThan(counter.value, 0)
        XCTAssertLessThanOrEqual(counter.value, 5)
    }

    // MARK: - increaseDedup — error cases

    func test_increase_dedup_empty_actor_throws() {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)

        // when / then
        XCTAssertThrowsError(try counter.increaseDedup(primitive, actor: "")) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError")
                return
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    func test_increase_dedup_value_not_one_throws() {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let nonUnit = Primitive(value: .integer(5), createdAt: TimeTicket.initial)

        // when / then — dedup counters only accept increment-by-1
        XCTAssertThrowsError(try counter.increaseDedup(nonUnit, actor: "actor-a")) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError")
                return
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    func test_increase_on_dedup_counter_throws() {
        // given — a dedup counter must not use the regular increase path
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)

        // when / then
        XCTAssertThrowsError(try counter.increase(primitive)) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError")
                return
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    // MARK: - increaseDedup — long primitive accepted

    func test_increase_dedup_accepts_long_primitive_with_value_one() throws {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .long(1), createdAt: TimeTicket.initial)

        // when
        try counter.increaseDedup(primitive, actor: "actor-a")

        // then
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - hllBytes / restoreHLL round-trip

    func test_hllBytes_returns_non_nil_for_dedup_counter() throws {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)
        try counter.increaseDedup(primitive, actor: "actor-a")

        // when
        let bytes = counter.hllBytes()

        // then
        XCTAssertNotNil(bytes)
        XCTAssertEqual(bytes?.count, 16384)
    }

    func test_hllBytes_returns_nil_for_regular_counter() {
        // given
        let counter = CRDTCounter(value: Int32(10), createdAt: TimeTicket.initial)

        // when / then
        XCTAssertNil(counter.hllBytes())
    }

    func test_restoreHLL_preserves_value() throws {
        // given — counter with one actor registered
        let original = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)
        try original.increaseDedup(primitive, actor: "actor-a")
        let serialised = original.hllBytes()!

        // when — restore into a fresh counter
        let restored = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        try restored.restoreHLL(serialised)

        // then
        XCTAssertEqual(restored.value, original.value)
    }

    func test_restoreHLL_on_regular_counter_throws() {
        // given
        let regular = CRDTCounter(value: Int32(0), createdAt: TimeTicket.initial)
        let fakeBytes = Data(repeating: 0, count: 16384)

        // when / then
        XCTAssertThrowsError(try regular.restoreHLL(fakeBytes)) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError")
                return
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    // MARK: - deepcopy

    func test_deepcopy_dedup_counter_preserves_state() throws {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)
        try counter.increaseDedup(primitive, actor: "actor-a")
        let originalValue = counter.value

        // when
        let copy = counter.deepcopy() as? CRDTCounter<Int32>

        // then
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy!.isDedup)
        XCTAssertEqual(copy!.value, originalValue)
    }

    func test_deepcopy_is_independent_from_original() throws {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)
        try counter.increaseDedup(primitive, actor: "actor-a")

        // when — copy, then mutate the original
        let copy = try XCTUnwrap(counter.deepcopy() as? CRDTCounter<Int32>)
        try counter.increaseDedup(primitive, actor: "actor-b")

        // then — the copy must be unchanged
        XCTAssertEqual(copy.value, 1)
    }

    // MARK: - toJSON / toSortedJSON

    func test_dedup_counter_to_json_reflects_cardinality() throws {
        // given
        let counter = CRDTCounter<Int32>(dedupWithCreatedAt: TimeTicket.initial)
        let primitive = Primitive(value: .integer(1), createdAt: TimeTicket.initial)
        try counter.increaseDedup(primitive, actor: "actor-a")

        // when / then
        XCTAssertEqual(counter.toJSON(), "1")
        XCTAssertEqual(counter.toSortedJSON(), "1")
    }
}

// MARK: - JSONDedupCounter unit tests

/// Tests for ``JSONDedupCounter`` that do not require the document-level
/// `JSONObject.set` integration.
///
/// NOTE: ``JSONObject/set(key:value:)`` does not yet handle
/// ``JSONDedupCounter`` — assigning `root.uv = JSONDedupCounter()` inside a
/// `doc.update` closure triggers `assertionFailure`. The missing case is a
/// known gap in Sources and must be added before the document-level happy-path
/// tests can run. The integration tests in `DedupCounterIntegrationTests` are
/// the canonical place to exercise the full sync round-trip once Sources
/// support is complete.
final class JSONDedupCounterTests: XCTestCase {
    // MARK: - add before initialization

    // Ports: mirrors JS `DedupCounter.increase()` pre-init guard.
    func test_add_before_init_throws_errNotInitialized() {
        // given — counter created but never attached to a document
        let counter = JSONDedupCounter()

        // when / then
        XCTAssertThrowsError(try counter.add("actor")) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError but got \(error)")
                return
            }
            XCTAssertEqual(yorkieError.code, .errNotInitialized)
        }
    }

    // MARK: - initial value

    func test_initial_value_is_zero() {
        // given / when
        let counter = JSONDedupCounter()

        // then — value is 0 before being connected to a document
        XCTAssertEqual(counter.value, 0)
    }

    // MARK: - id is nil before initialization

    func test_id_is_nil_before_init() {
        // given / when
        let counter = JSONDedupCounter()

        // then
        XCTAssertNil(counter.id, "id must be nil before the counter is added to a document")
    }
}
