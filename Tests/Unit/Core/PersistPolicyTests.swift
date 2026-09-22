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

/// Pins `shouldCompact(_:)`, the append-or-compact decision `Client.persistToStore` reads.
/// Nothing in `Tests/Integration` exercises the byte-threshold or the count-threshold
/// boundary directly -- a convergence test would need a document that grows exactly one
/// byte past a ratio, which is not something a JSON edit can be relied on to produce -- so
/// the boundaries are pinned here against `PersistState` values chosen by hand instead.
final class PersistPolicyTests: XCTestCase {
    // MARK: Below both thresholds

    func test_shouldcompact_is_false_below_both_thresholds() {
        let state = PersistState(snapshotBytes: 200_000, logBytes: 1024, changeCount: 5)

        XCTAssertFalse(shouldCompact(state))
    }

    // MARK: changeCount boundary

    func test_shouldcompact_is_false_at_exactly_maxreplay_changes() {
        // `maxReplay` is a latency budget: replaying exactly 1000 changes on restore is still
        // within it, so this must not yet trip the count rule. Byte sizes are kept far below
        // their own threshold so only the count rule is under test.
        let state = PersistState(snapshotBytes: 200_000, logBytes: 1024, changeCount: maxReplay)

        XCTAssertFalse(shouldCompact(state))
    }

    func test_shouldcompact_is_true_one_change_past_maxreplay() {
        let state = PersistState(snapshotBytes: 200_000, logBytes: 1024, changeCount: maxReplay + 1)

        XCTAssertTrue(shouldCompact(state))
    }

    // MARK: Byte boundary -- small snapshot, floor dominates

    func test_shouldcompact_is_false_just_under_the_floor_for_a_small_snapshot() {
        // snapshotBytes * logRatio (250) is far below minLogBytes (65536), so the floor -- not
        // the ratio -- is what the log has to clear.
        let state = PersistState(snapshotBytes: 500, logBytes: minLogBytes - 1, changeCount: 1)

        XCTAssertFalse(shouldCompact(state))
    }

    func test_shouldcompact_is_true_just_over_the_floor_for_a_small_snapshot() {
        let state = PersistState(snapshotBytes: 500, logBytes: minLogBytes + 1, changeCount: 1)

        XCTAssertTrue(shouldCompact(state))
    }

    func test_a_500_byte_document_does_not_compact_after_two_changes() {
        // The floor's whole reason to exist: without it, `snapshotBytes * logRatio` alone
        // would make the smallest documents the busiest, compacting a 500-byte document after
        // just two small changes. Two short changes land nowhere near 64KB.
        let state = PersistState(snapshotBytes: 500, logBytes: 200, changeCount: 2)

        XCTAssertFalse(shouldCompact(state), "the floor should keep a tiny document from compacting this early")
    }

    // MARK: Byte boundary -- large snapshot, ratio dominates

    func test_shouldcompact_is_false_just_under_the_ratio_for_a_large_snapshot() {
        // snapshotBytes * logRatio (100,000) comfortably exceeds minLogBytes (65536), so the
        // ratio -- not the floor -- is what the log has to clear here.
        let snapshotBytes = 200_000
        let threshold = Int(Double(snapshotBytes) * logRatio)
        XCTAssertGreaterThan(threshold, minLogBytes, "the ratio must be the binding threshold for this fixture")

        let state = PersistState(snapshotBytes: snapshotBytes, logBytes: threshold - 1, changeCount: 1)

        XCTAssertFalse(shouldCompact(state))
    }

    func test_shouldcompact_is_true_just_over_the_ratio_for_a_large_snapshot() {
        let snapshotBytes = 200_000
        let threshold = Int(Double(snapshotBytes) * logRatio)

        let state = PersistState(snapshotBytes: snapshotBytes, logBytes: threshold + 1, changeCount: 1)

        XCTAssertTrue(shouldCompact(state))
    }
}
