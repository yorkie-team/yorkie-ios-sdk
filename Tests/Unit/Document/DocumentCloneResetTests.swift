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
}
