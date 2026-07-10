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

// Port of yorkie-js-sdk packages/sdk/test/unit/document/disable_presence_test.ts at v0.7.12.
//
// NOTE: the JS suite spies on `console.warn` to assert the presence-drop warning fires at most
// once per document. There is no equivalent seam here without touching `Sources/Core/Logger.swift`
// (which is process-global and lazily bound to the first caller, so a test-side handler swap would
// be order-dependent and flaky across the suite) — per task constraints we do not modify `Sources`.
// Those cases are ported for their *observable* assertions only (presence dropped / not dropped);
// the warn-call-count assertions are omitted with this note in place of a fragile spy.
final class DisablePresenceTests: XCTestCase {
    // Ports: "round-trips through DocumentOptions to isPresenceDisabled"
    @MainActor
    func test_round_trips_through_documentoptions_to_ispresencedisabled() {
        let doc = Document(key: "test-doc", opts: DocumentOptions(disableGC: false, disablePresence: true))
        XCTAssertTrue(doc.isPresenceDisabled())

        let docDefault = Document(key: "test-doc-default")
        XCTAssertFalse(docDefault.isPresenceDisabled())

        let docExplicitFalse = Document(key: "test-doc-explicit-false", opts: DocumentOptions(disableGC: false, disablePresence: false))
        XCTAssertFalse(docExplicitFalse.isPresenceDisabled())
    }

    // Ports: "drops presence-only update silently when option is on"
    @MainActor
    func test_drops_presence_only_update_silently_when_option_is_on() throws {
        let doc = Document(key: "test-doc", opts: DocumentOptions(disableGC: false, disablePresence: true))
        let actorID = try XCTUnwrap(doc.actorID)

        try doc.update { _, presence in
            presence.set(["cursor": 7])
        }

        // No presence recorded for the actor — the change collapsed (no operations + dropped
        // presence emit).
        XCTAssertFalse(doc.hasPresence(actorID))
    }

    // Ports: "warns at most once per document across many drops" (observable half — see file header).
    @MainActor
    func test_repeated_drops_never_surface_presence_for_the_actor() throws {
        let doc = Document(key: "test-doc", opts: DocumentOptions(disableGC: false, disablePresence: true))
        let actorID = try XCTUnwrap(doc.actorID)

        for index in 0 ..< 5 {
            try doc.update { _, presence in
                presence.set(["cursor": index])
            }
        }

        XCTAssertFalse(doc.hasPresence(actorID))
    }

    // Ports: "preserves operations on a mixed change even when presence is dropped"
    @MainActor
    func test_preserves_operations_on_a_mixed_change_even_when_presence_is_dropped() throws {
        let doc = Document(key: "test-doc", opts: DocumentOptions(disableGC: false, disablePresence: true))
        let actorID = try XCTUnwrap(doc.actorID)

        try doc.update { root, presence in
            root.count = Int64(42)
            presence.set(["cursor": 9])
        }

        // Operation persisted on the root.
        XCTAssertEqual(doc.getRoot().count as? Int64, 42)
        // Presence dropped — no entry for the actor.
        XCTAssertFalse(doc.hasPresence(actorID))
    }

    // Ports: "allows presence to flow when option is off"
    @MainActor
    func test_allows_presence_to_flow_when_option_is_off() throws {
        let doc = Document(key: "test-doc")
        let actorID = try XCTUnwrap(doc.actorID)

        try doc.update { _, presence in
            presence.set(["cursor": 3])
        }

        // Presence recorded for the actor.
        XCTAssertTrue(doc.hasPresence(actorID))
    }

    // Ports: "honours setDisablePresence flipped after construction"
    @MainActor
    func test_honours_setdisablepresence_flipped_after_construction() throws {
        let doc = Document(key: "test-doc")
        let actorID = try XCTUnwrap(doc.actorID)
        XCTAssertFalse(doc.isPresenceDisabled())

        // Flip on — subsequent updates should drop presence.
        doc.setDisablePresence(true)
        XCTAssertTrue(doc.isPresenceDisabled())
        try doc.update { _, presence in
            presence.set(["cursor": 1])
        }
        XCTAssertFalse(doc.hasPresence(actorID))

        // Flip off — presence flows again.
        doc.setDisablePresence(false)
        XCTAssertFalse(doc.isPresenceDisabled())
        try doc.update { _, presence in
            presence.set(["cursor": 2])
        }
        XCTAssertTrue(doc.hasPresence(actorID))
    }
}

// Ports: "ChangeContext presenceless accessors" describe block.
final class ChangeContextPresencelessAccessorsTests: XCTestCase {
    private func makeContext() -> ChangeContext {
        ChangeContext(prevID: ChangeID.initial, root: CRDTRoot())
    }

    // Ports: "hasPresenceChange reflects setPresenceChange / dropPresenceChange"
    func test_haspresencechange_reflects_direct_assignment_and_droppresencechange() {
        let ctx = self.makeContext()
        XCTAssertFalse(ctx.hasPresenceChange())

        ctx.presenceChange = .put(presence: [:])
        XCTAssertTrue(ctx.hasPresenceChange())

        ctx.dropPresenceChange()
        XCTAssertFalse(ctx.hasPresenceChange())
    }

    // Ports: "dropPresenceChange leaves a presence-only context with no change"
    func test_droppresencechange_leaves_a_presence_only_context_with_no_change() {
        let ctx = self.makeContext()
        ctx.presenceChange = .put(presence: [:])
        XCTAssertTrue(ctx.hasChange)

        ctx.dropPresenceChange()
        XCTAssertFalse(ctx.hasChange)
    }
}
