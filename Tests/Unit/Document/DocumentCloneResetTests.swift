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

/// Shared call counter so `FaultInjectingOperation` can fail on a specific
/// invocation across the clone-then-root execution pair, mirroring
/// yorkie-js-sdk's `throwOnNthCall` (`vi.spyOn(SetOperation.prototype, 'execute')`
/// in `clone_reset_test.ts`). Swift has no prototype to patch, so the fault is
/// injected through a dedicated `Operation` instead of a spy on a real one.
private final class CallCounter {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        self.count += 1
        return self.count
    }
}

/// An `Operation` that throws on its `failOnCall`th invocation and succeeds
/// otherwise. `applyChangeInternal` and `executeUndoRedoInternal` each run a
/// change's operations twice -- once against the clone's root, once against the
/// document's root -- so `failOnCall: 2` fails the second (root) pass only,
/// reproducing "a change that fails partway".
private struct FaultInjectingOperation: Yorkie.Operation {
    let parentCreatedAt: TimeTicket
    var executedAt: TimeTicket
    let failOnCall: Int
    let counter: CallCounter

    var effectedCreatedAt: TimeTicket { self.executedAt }
    var toTestString: String { "FAULT" }

    func execute(root: CRDTRoot, versionVector: VersionVector?, source: OpSource) throws -> ExecutionResult? {
        if self.counter.increment() == self.failOnCall {
            throw YorkieError(code: .errUnexpected, message: "boom")
        }
        return ExecutionResult(opInfos: [], reverseOp: nil)
    }
}

/// An `Operation` that writes a `Primitive` integer under `key` into the root object on success,
/// and throws on its `failOnCall`th invocation instead of writing anything. Two instances
/// sharing one `CallCounter` reproduce "a change whose first operation lands for real and whose
/// second throws" (yorkie-js-sdk#1397's `throwOnNthCall(2)` over `r.a = 1; r.b = 2`), which
/// `FaultInjectingOperation` cannot: it never writes, so there would be nothing to observe as
/// "landed".
private struct FaultInjectingSetOperation: Yorkie.Operation {
    let parentCreatedAt: TimeTicket
    var executedAt: TimeTicket
    let key: String
    let value: Int64
    let failOnCall: Int
    let counter: CallCounter

    var effectedCreatedAt: TimeTicket { self.executedAt }
    var toTestString: String { "FAULT_SET(\(self.key))" }

    func execute(root: CRDTRoot, versionVector: VersionVector?, source: OpSource) throws -> ExecutionResult? {
        if self.counter.increment() == self.failOnCall {
            throw YorkieError(code: .errUnexpected, message: "boom")
        }
        guard let parent = root.find(createdAt: self.parentCreatedAt) as? CRDTObject else {
            throw YorkieError(code: .errUnexpected, message: "root object not found")
        }
        let primitive = Primitive(value: .long(self.value), createdAt: self.executedAt)
        let removed = parent.set(key: self.key, value: primitive, executedAt: self.executedAt)
        root.registerElement(primitive, parent: parent)
        if let removed {
            root.registerRemovedElement(removed)
        }
        return ExecutionResult(opInfos: [], reverseOp: nil)
    }
}

/// Ported from yorkie-js-sdk#1394 "Guard empty-text anchors and reset the clone
/// on failed applies": `packages/sdk/test/unit/document/clone_reset_test.ts`.
///
/// `Change.execute` does not roll back, so a change that fails partway leaves
/// the clone and the root holding different prefixes of it. `applyChange` and
/// `executeUndoRedo` must drop the clone on that path the way `Document.update`
/// already does on an updater throw (0.7.21).
final class DocumentCloneResetTests: XCTestCase {
    private let actorA = "000000000000000000000001"

    @MainActor
    func test_drops_the_clone_when_a_remote_change_fails_partway() throws {
        // given
        let target = Document(key: "clone-reset-remote")
        target.setActor(self.actorA)

        let counter = CallCounter()
        let changeID = ChangeID(
            clientSeq: 1,
            lamport: 1,
            actor: self.actorA,
            versionVector: VersionVector(vector: [self.actorA: 1])
        )
        let op = FaultInjectingOperation(parentCreatedAt: .initial, executedAt: .initial, failOnCall: 2, counter: counter)
        let change = Change(id: changeID, operations: [op])

        // when -- the clone takes the change on the 1st call, then the root pass (2nd call) throws.
        XCTAssertThrowsError(try target.applyChanges([change], source: .remote))

        // then -- the clone must not survive holding a prefix the root never took.
        XCTAssertNil(target.getClone())
    }

    @MainActor
    func test_drops_the_clone_when_an_undo_fails_partway() throws {
        // given
        let target = Document(key: "clone-reset-undo")
        target.setActor(self.actorA)

        let counter = CallCounter()
        let op = FaultInjectingOperation(parentCreatedAt: .initial, executedAt: .initial, failOnCall: 2, counter: counter)
        target.pushUndoForTest([.operation(op)])

        // when -- the clone takes the reverse op on the 1st call, then the root pass (2nd call) throws.
        XCTAssertThrowsError(try target.undo())

        // then -- a partially executed undo leaves the clone ahead of the root; it must be dropped.
        XCTAssertNil(target.getClone())
    }

    @MainActor
    func test_keeps_the_clone_when_undo_is_refused_during_an_update() throws {
        // given -- an updater holds a proxy over the clone, and `update` reads it again when the
        // updater returns, so the refusal undo hits while updating must not drop it out from under it.
        let doc = Document(key: "clone-reset-refused")
        try doc.update { root, _ in
            root.k = Int64(1)
        }

        // when
        try doc.update { root, _ in
            XCTAssertThrowsError(try doc.undo()) { error in
                guard let yorkieError = error as? YorkieError else {
                    return XCTFail("expected a YorkieError, got \(error)")
                }
                XCTAssertEqual(yorkieError.code, .errRefused)
            }
            root.k = Int64(2)
        }

        // then -- the update completed normally; undo's refusal never touched the clone.
        XCTAssertEqual(doc.getRoot().k as? Int64, 2)
    }

    /// Ported from yorkie-js-sdk#1397 "Burn the lamport when a change's root pass throws":
    /// the four tests `clone_reset_test.ts` added alongside it.
    ///
    /// `Document.update` mutates the clone directly through the `JSONObject` proxy rather than
    /// through `Operation.execute` (unlike `applyChange`/`executeUndoRedo`, which run a change
    /// against the clone and the root in turn), so the single `change.execute(root: self.root)`
    /// call these tests drive through `updateWithOperationForTest` IS the root pass -- there is
    /// no earlier clone-side `execute` call to distinguish it from, mirroring JS's own comment
    /// that every `SetOperation.execute` call `Document.update` makes is a root-pass call.
    @MainActor
    func test_drops_the_clone_when_a_local_change_fails_on_the_root() throws {
        // given
        let target = Document(key: "lamport-burn-clone")
        target.setActor(self.actorA)

        let counter = CallCounter()
        let op = FaultInjectingOperation(parentCreatedAt: .initial, executedAt: .initial, failOnCall: 1, counter: counter)

        // when -- the one and only execute call (the root pass) throws immediately.
        XCTAssertThrowsError(try target.updateWithOperationForTest([op]))

        // then
        XCTAssertNil(target.getClone())
    }

    // Pins the known gap the clone reset does not close, so a change in this contract is a
    // deliberate one: a failed `update` records nothing, so the prefix that reached the root is
    // local-only state.
    @MainActor
    func test_records_nothing_for_a_local_change_that_fails_on_the_root() async throws {
        // given
        let target = Document(key: "lamport-burn-records-nothing")
        target.setActor(self.actorA)

        let counter = CallCounter()
        // `executedAt` becomes the written primitive's createdAt, which must not collide with
        // the root object's own `.initial` ticket in the createdAt registry.
        let opA = FaultInjectingSetOperation(
            parentCreatedAt: .initial,
            executedAt: TimeTicket(lamport: 1, delimiter: 1, actorID: self.actorA),
            key: "a", value: 1, failOnCall: 2, counter: counter
        )
        let opB = FaultInjectingSetOperation(
            parentCreatedAt: .initial,
            executedAt: TimeTicket(lamport: 1, delimiter: 2, actorID: self.actorA),
            key: "b", value: 2, failOnCall: 2, counter: counter
        )

        // when -- "a" lands (1st call), "b" throws (2nd call).
        XCTAssertThrowsError(try target.updateWithOperationForTest([opA, opB]))

        // then -- the prefix is in the root and stays there, unqueued.
        XCTAssertEqual(target.toSortedJSON(), "{\"a\":1}")
        let hasLocalChanges = await target.hasLocalChanges()
        XCTAssertFalse(hasLocalChanges)
        XCTAssertFalse(target.canUndo)

        try target.update { root, _ in
            root.c = Int64(3)
        }
        // The counter is untouched -- nothing was queued, so the next change is still this
        // client's first and leaves no hole for the server to reject.
        XCTAssertEqual(target.changeID.getClientSeq(), 1)
    }

    // The other half of that contract, and the reason the failed change still has to leave a
    // trace: the prefix burned its TimeTickets into the root, so the next change must not
    // reissue them.
    @MainActor
    func test_does_not_reissue_the_tickets_a_failed_local_change_burned() throws {
        // given
        let target = Document(key: "lamport-burn-no-reissue")
        target.setActor(self.actorA)
        let before = target.changeID.getLamport()

        let counter = CallCounter()
        // `executedAt` becomes the written primitive's createdAt, which must not collide with
        // the root object's own `.initial` ticket in the createdAt registry.
        let opA = FaultInjectingSetOperation(
            parentCreatedAt: .initial,
            executedAt: TimeTicket(lamport: 1, delimiter: 1, actorID: self.actorA),
            key: "a", value: 1, failOnCall: 2, counter: counter
        )
        let opB = FaultInjectingSetOperation(
            parentCreatedAt: .initial,
            executedAt: TimeTicket(lamport: 1, delimiter: 2, actorID: self.actorA),
            key: "b", value: 2, failOnCall: 2, counter: counter
        )

        // when
        XCTAssertThrowsError(try target.updateWithOperationForTest([opA, opB]))

        // then -- the lamport the prefix issued its tickets under is spent, even though the
        // change it belonged to was never recorded.
        XCTAssertGreaterThan(target.changeID.getLamport(), before)

        try target.update { root, _ in
            root.c = Int64(3)
        }

        // Both "a" (the landed prefix) and "c" (the next change) are reachable with their own
        // values, i.e. neither took over the other's slot.
        XCTAssertEqual(target.toSortedJSON(), "{\"a\":1,\"c\":3}")
    }

    // Pins the other half of that contract: `Change.execute` applies the presence change only
    // after every operation has succeeded, so a change that throws partway carries its presence
    // no further than its operations.
    @MainActor
    func test_applies_no_presence_for_a_local_change_that_fails_on_the_root() throws {
        // given
        let target = Document(key: "lamport-burn-no-presence")
        target.setActor(self.actorA)

        let counter = CallCounter()
        let op = FaultInjectingOperation(parentCreatedAt: .initial, executedAt: .initial, failOnCall: 1, counter: counter)

        // when
        XCTAssertThrowsError(try target.updateWithOperationForTest([op], presence: StringValueTypeDictionary.stringifyAttributes(["cursor": 1])))

        // then
        XCTAssertNil(target.getPresenceForTest(self.actorA))

        // The same shape without a throwing operation does record the presence, so the assertion
        // above is about the failure and not about presence never reaching `presences` here.
        try target.updateWithOperationForTest([], presence: StringValueTypeDictionary.stringifyAttributes(["cursor": 2]))
        XCTAssertEqual(target.getPresenceForTest(self.actorA)?["cursor"] as? Int, 2)
    }
}
