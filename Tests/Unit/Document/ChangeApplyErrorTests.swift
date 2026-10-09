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

/// Ported from `change_apply_error_test.ts` (yorkie-js-sdk#1403).
///
/// iOS has no class hierarchy for `YorkieError` -- it is a flat `{code, message}` struct, not a
/// base class a `ChangeApplyError` subclass could extend with structured `docKey`/`changeID`/
/// `opIndex`/`operation`/`cause` fields and a `withDocKey` method. The port instead folds that
/// same metadata into the message of a `YorkieError` carrying the new `.errChangeApplyFailed`
/// code, composed in two stages exactly where JS composes its two field-sets: `Change.execute`
/// names the operation (only place it is known) and `Document.applyChange` adds the document key
/// (only place that is known) as the error passes through.
///
/// A real, deterministic precondition failure (`SetOperation` targeting a `parentCreatedAt` that
/// does not exist in the root) stands in for JS's `vi.spyOn` fault injection, since Swift has no
/// production-code mocking seam here.
@MainActor
class ChangeApplyErrorTests: XCTestCase {
    private let actorID = "000000000000000000000001"

    /// A change with one `SetOperation` whose `parentCreatedAt` is never registered in any
    /// document's root, so `executeOpInfos` throws `errInvalidArgument` ("failed to find ...")
    /// the moment it runs -- deterministically, with no mocking required.
    private func changeWithUnresolvableParent() -> (change: Change, missingParent: TimeTicket, valueCreatedAt: TimeTicket) {
        let missingParent = TimeTicket(lamport: 99, delimiter: 0, actorID: self.actorID)
        let valueCreatedAt = TimeTicket(lamport: 100, delimiter: 0, actorID: self.actorID)
        let setOperation = SetOperation(
            key: "k",
            value: Primitive(value: .string("v"), createdAt: valueCreatedAt),
            parentCreatedAt: missingParent,
            executedAt: valueCreatedAt
        )
        let changeID = ChangeID(
            clientSeq: 1,
            lamport: 100,
            actor: self.actorID,
            versionVector: VersionVector(vector: [self.actorID: 100])
        )
        return (Change(id: changeID, operations: [setOperation]), missingParent, valueCreatedAt)
    }

    func test_names_the_document_the_change_and_the_operation() throws {
        // given
        let doc = Document(key: "d")
        let (change, missingParent, _) = self.changeWithUnresolvableParent()

        // when
        var thrown: YorkieError?
        do {
            try doc.applyChanges([change], source: .remote)
            XCTFail("expected applyChanges to throw")
        } catch let error as YorkieError {
            thrown = error
        }

        // then
        let error = try XCTUnwrap(thrown)
        XCTAssertEqual(error.code, .errChangeApplyFailed)
        XCTAssertTrue(error.message.contains("document \"d\""), error.message)
        XCTAssertTrue(error.message.contains(change.id.toTestString), error.message)
        XCTAssertTrue(error.message.contains("operation 0"), error.message)
        XCTAssertTrue(error.message.contains("SetOperation"), error.message)
        XCTAssertTrue(error.message.contains(missingParent.toTestString), error.message)
    }

    func test_never_carries_the_operation_payload_into_the_message() throws {
        // given — the operation's own debug serializer embeds the value it set ("v"), which
        // must never appear in a message reaching application logs on every redelivery.
        let doc = Document(key: "d")
        let (change, _, _) = self.changeWithUnresolvableParent()
        let payload = change.operations[0].toTestString

        // when
        var thrown: YorkieError?
        do {
            try doc.applyChanges([change], source: .remote)
            XCTFail("expected applyChanges to throw")
        } catch let error as YorkieError {
            thrown = error
        }

        // then
        let error = try XCTUnwrap(thrown)
        XCTAssertFalse(error.message.contains(payload), "payload \"\(payload)\" leaked into \"\(error.message)\"")
    }

    func test_leaves_the_error_of_a_local_or_undo_redo_replay_untouched() throws {
        for source: OpSource in [.local, .undoRedo] {
            // given
            let doc = Document(key: "d")
            let (change, _, _) = self.changeWithUnresolvableParent()

            // when
            var thrown: YorkieError?
            do {
                try doc.applyChanges([change], source: source)
                XCTFail("expected applyChanges to throw")
            } catch let error as YorkieError {
                thrown = error
            }

            // then — the caller that asked for this replay matches on the code the operation
            // itself threw, not a wrapped redelivery-diagnostic code.
            let error = try XCTUnwrap(thrown)
            XCTAssertEqual(error.code, .errInvalidArgument)
        }
    }

    func test_reports_the_stuck_checkpoint_when_a_pack_cannot_be_applied() throws {
        // given
        let doc = Document(key: "d")
        let (change, _, _) = self.changeWithUnresolvableParent()
        let pack = ChangePack(
            key: doc.getKey(),
            checkpoint: Checkpoint(serverSeq: 1, clientSeq: 0),
            isRemoved: false,
            changes: [change],
            versionVector: VersionVector(vector: [self.actorID: 100])
        )

        // when
        var thrown: YorkieError?
        do {
            try doc.applyChangePack(pack)
            XCTFail("expected applyChangePack to throw")
        } catch let error as YorkieError {
            thrown = error
        }

        // then — the checkpoint has not advanced, so the server redelivers this pack.
        XCTAssertEqual(thrown?.code, .errChangeApplyFailed)
        XCTAssertEqual(doc.checkpoint.getServerSeq(), 0)
    }
}
