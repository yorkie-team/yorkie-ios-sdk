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

/// Ported from `remote_skip_test.ts` (yorkie-js-sdk#1502).
///
/// The JS-only case for a non-JSON presence (#1509) has no Swift analogue: presence travels as a
/// `[String: String]` map on the wire here, so there is nothing to fail to parse.
@MainActor
final class RemoteSkipTests: XCTestCase {
    private let actorID = "000000000000000000000001"
    private var counterCreatedAt: TimeTicket {
        TimeTicket(lamport: 1, delimiter: 1, actorID: self.actorID)
    }

    private func changeID(clientSeq: UInt32, lamport: Int64) -> ChangeID {
        ChangeID(clientSeq: clientSeq, lamport: lamport, actor: self.actorID,
                 versionVector: VersionVector(vector: [self.actorID: lamport]))
    }

    /// The change that creates the dedup counter under the key `uv`.
    private func createCounterChange() -> Change {
        let set = SetOperation(
            key: "uv",
            value: CRDTCounter<Int32>(dedupWithCreatedAt: self.counterCreatedAt),
            parentCreatedAt: TimeTicket.initial,
            executedAt: self.counterCreatedAt
        )
        return Change(id: self.changeID(clientSeq: 1, lamport: 1), operations: [set])
    }

    /// A change carrying a single increase of the counter, as a non-SDK writer could push it.
    private func increaseChange(value: Int32, actor: String, clientSeq: UInt32 = 2, lamport: Int64 = 2) -> Change {
        let id = self.changeID(clientSeq: clientSeq, lamport: lamport)
        let op = IncreaseOperation(
            parentCreatedAt: self.counterCreatedAt,
            value: Primitive(value: .integer(value), createdAt: id.createTimeTicket(delimiter: 1)),
            executedAt: id.createTimeTicket(delimiter: 2),
            actor: actor
        )
        return Change(id: id, operations: [op])
    }

    private func targetWithCounter() throws -> Document {
        let target = Document(key: "d")
        try target.applyChanges([self.createCounterChange()], source: .remote)
        return target
    }

    private func counterValue(_ doc: Document) -> Int32? {
        (doc.getRootObject().get(key: "uv") as? CRDTCounter<Int32>)?.value
    }

    func test_applies_a_dedup_increase_that_carries_an_actor_and_a_unit_delta() throws {
        // given
        let target = try self.targetWithCounter()

        // when / then - skipping must not swallow the applicable shape
        try target.applyChanges([self.increaseChange(value: 1, actor: "actor-a", clientSeq: 2, lamport: 2)], source: .remote)
        XCTAssertEqual(self.counterValue(target), 1)

        // the same actor again is deduplicated, a second actor counts
        try target.applyChanges([self.increaseChange(value: 1, actor: "actor-a", clientSeq: 3, lamport: 3)], source: .remote)
        XCTAssertEqual(self.counterValue(target), 1)
        try target.applyChanges([self.increaseChange(value: 1, actor: "actor-b", clientSeq: 4, lamport: 4)], source: .remote)
        XCTAssertEqual(self.counterValue(target), 2)
    }

    func test_skips_a_dedup_increase_that_carries_no_actor() throws {
        // given - a later change in the same pack must still land
        let target = try self.targetWithCounter()
        let bad = self.increaseChange(value: 1, actor: "")
        let goodID = self.changeID(clientSeq: 3, lamport: 3)
        let good = Change(id: goodID, operations: [SetOperation(
            key: "k",
            value: Primitive(value: .string("v"), createdAt: goodID.createTimeTicket(delimiter: 1)),
            parentCreatedAt: TimeTicket.initial,
            executedAt: goodID.createTimeTicket(delimiter: 1)
        )])
        let pack = ChangePack(
            key: "d",
            checkpoint: Checkpoint(serverSeq: 2, clientSeq: 0),
            isRemoved: false,
            changes: [bad, good],
            versionVector: VersionVector.initial
        )

        // when
        try target.applyChangePack(pack)

        // then
        XCTAssertEqual(self.counterValue(target), 0)
        XCTAssertEqual((target.getRootObject().get(key: "k") as? Primitive)?.value, .string("v"))
        XCTAssertEqual(target.checkpoint.getServerSeq(), 2)
    }

    func test_skips_a_dedup_increase_whose_delta_the_counter_refuses() throws {
        // given
        let target = try self.targetWithCounter()

        // when / then
        XCTAssertNoThrow(try target.applyChanges([self.increaseChange(value: 2, actor: "actor-a")], source: .remote))
        XCTAssertEqual(self.counterValue(target), 0)
    }

    func test_skips_a_dedup_increase_whose_value_is_not_a_primitive() throws {
        // given - a value the counter cannot take, as a non-SDK writer could push it
        let target = try self.targetWithCounter()
        let id = self.changeID(clientSeq: 2, lamport: 2)
        let op = IncreaseOperation(
            parentCreatedAt: self.counterCreatedAt,
            value: CRDTObject(createdAt: id.createTimeTicket(delimiter: 1)),
            executedAt: id.createTimeTicket(delimiter: 2),
            actor: "actor-a"
        )

        // when / then - skipped on the pull path instead of failing the pack
        XCTAssertNoThrow(try target.applyChanges([Change(id: id, operations: [op])], source: .remote))
        XCTAssertEqual(self.counterValue(target), 0)
    }

    func test_still_reports_a_local_dedup_increase_that_cannot_be_applied() throws {
        // given
        let target = try self.targetWithCounter()
        let crdtRoot = CRDTRoot(rootObject: target.getRootObject())

        for source in [OpSource.local, OpSource.undoRedo] {
            // when / then - no actor
            let noActor = try XCTUnwrap(self.increaseChange(value: 1, actor: "").operations.first)
            XCTAssertThrowsError(try noActor.execute(root: crdtRoot, versionVector: nil, source: source)) { error in
                XCTAssertTrue((error as? YorkieError)?.message.contains("dedup counter requires actor") == true, "\(error)")
            }

            // when / then - delta the counter refuses
            let badDelta = try XCTUnwrap(self.increaseChange(value: 2, actor: "actor-a").operations.first)
            XCTAssertThrowsError(try badDelta.execute(root: crdtRoot, versionVector: nil, source: source)) { error in
                XCTAssertTrue((error as? YorkieError)?.message.contains("dedup counter only supports increment by 1") == true, "\(error)")
            }
        }
    }

    func test_decodes_UNSPECIFIED_and_DELETE_as_an_empty_presence_as_Go_does() throws {
        for type in [Yorkie_V1_PresenceChange.ChangeType.unspecified, .delete] {
            // given
            let actor = "000000000000000000000002"
            let doc = Document(key: "d")
            doc.setActor(actor)
            try doc.update { root, presence in
                root.k = "v"
                presence.set(["name": "a"])
            }
            var pbPack = Converter.toChangePack(pack: doc.createChangePack())
            pbPack.changes[0].presenceChange.type = type
            pbPack.changes[0].presenceChange.clearPresence()

            // when
            let change = try XCTUnwrap(Converter.fromChangePack(pbPack).getChanges().first)

            // then
            guard case .put(let presence)? = change.presenceChange else {
                return XCTFail("expected an empty put, got \(String(describing: change.presenceChange))")
            }
            XCTAssertTrue(presence.isEmpty)

            // Go's `Change.Execute` stores the decoded empty presence for the actor, and the
            // operations of the change still apply.
            var presences: [ActorID: StringValueTypeDictionary] = [actor: ["name": "\"a\""]]
            let root = CRDTRoot()
            _ = try change.execute(root: root, presences: &presences, source: .remote)
            XCTAssertEqual(presences[actor], [:])
            XCTAssertEqual(root.object.toJSON(), "{\"k\":\"v\"}")
        }
    }

    func test_decodes_a_PATCH_that_carries_no_presence_as_an_empty_one() throws {
        // given
        let doc = Document(key: "d")
        try doc.update { _, presence in presence.set(["name": "a"]) }
        var pbPack = Converter.toChangePack(pack: doc.createChangePack())
        pbPack.changes[0].presenceChange.type = .patch
        pbPack.changes[0].presenceChange.clearPresence()

        // when
        let change = try XCTUnwrap(Converter.fromChangePack(pbPack).getChanges().first)

        // then
        guard case .patch(let presence, _)? = change.presenceChange else {
            return XCTFail("expected a patch, got \(String(describing: change.presenceChange))")
        }
        XCTAssertTrue(presence.isEmpty)
    }

    func test_rejects_a_presence_change_outside_the_enum() throws {
        // given
        let doc = Document(key: "d")
        try doc.update { _, presence in presence.set(["name": "a"]) }
        var pbPack = Converter.toChangePack(pack: doc.createChangePack())
        pbPack.changes[0].presenceChange.type = .UNRECOGNIZED(42)

        // when / then
        XCTAssertThrowsError(try Converter.fromChangePack(pbPack)) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidType)
        }
    }
}
