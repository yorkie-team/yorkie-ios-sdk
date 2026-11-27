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
/// The JS-only case for a non-JSON presence (#1509) has no failing Swift analogue: presence travels as
/// a `[String: String]` map on the wire here, so there is nothing to fail to parse. It is pinned in
/// `PresenceValueTests` (yorkie-js-sdk#1559).
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

    // MARK: - Plain counters (yorkie-js-sdk#1525)

    private var plainCounterCreatedAt: TimeTicket {
        TimeTicket(lamport: 1, delimiter: 1, actorID: self.actorID)
    }

    private func createPlainCounterChange<T: YorkieCountable>(_ type: T.Type, initial: T) -> Change {
        let set = SetOperation(
            key: "c",
            value: CRDTCounter<T>(value: initial, createdAt: self.plainCounterCreatedAt),
            parentCreatedAt: TimeTicket.initial,
            executedAt: self.plainCounterCreatedAt
        )
        return Change(id: self.changeID(clientSeq: 1, lamport: 1), operations: [set])
    }

    private func plainIncrease(_ value: PrimitiveValue, clientSeq: UInt32 = 2, lamport: Int64 = 2) -> Change {
        let id = self.changeID(clientSeq: clientSeq, lamport: lamport)
        let op = IncreaseOperation(
            parentCreatedAt: self.plainCounterCreatedAt,
            value: Primitive(value: value, createdAt: id.createTimeTicket(delimiter: 1)),
            executedAt: id.createTimeTicket(delimiter: 2)
        )
        return Change(id: id, operations: [op])
    }

    private func plainTarget<T: YorkieCountable>(_ type: T.Type, initial: T) throws -> Document {
        let target = Document(key: "d")
        try target.applyChanges([self.createPlainCounterChange(type, initial: initial)], source: .remote)
        return target
    }

    private func plainValue<T: YorkieCountable>(_ doc: Document, _: T.Type) -> T? {
        (doc.getRootObject().get(key: "c") as? CRDTCounter<T>)?.value
    }

    func test_skips_a_plain_increase_whose_delta_the_counter_refuses() throws {
        // given - a later change in the same pack must still land
        let target = try self.plainTarget(Int32.self, initial: 0)
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
            changes: [self.plainIncrease(.string("1")), good],
            versionVector: VersionVector.initial
        )

        // when
        try target.applyChangePack(pack)

        // then
        XCTAssertEqual(self.plainValue(target, Int32.self), 0)
        XCTAssertEqual((target.getRootObject().get(key: "k") as? Primitive)?.value, .string("v"))
        XCTAssertEqual(target.checkpoint.getServerSeq(), 2)
    }

    func test_skips_an_increase_whose_value_is_not_a_primitive() throws {
        // given - a value the counter cannot take, as a non-SDK writer could push it
        let id = self.changeID(clientSeq: 2, lamport: 2)
        let op = IncreaseOperation(
            parentCreatedAt: self.plainCounterCreatedAt,
            value: CRDTObject(createdAt: id.createTimeTicket(delimiter: 1)),
            executedAt: id.createTimeTicket(delimiter: 2)
        )
        let change = Change(id: id, operations: [op])

        // when / then - an Int32 counter
        let int32Target = try self.plainTarget(Int32.self, initial: 0)
        XCTAssertNoThrow(try int32Target.applyChanges([change], source: .remote))
        XCTAssertEqual(self.plainValue(int32Target, Int32.self), 0)

        // when / then - an Int64 counter
        let int64Target = try self.plainTarget(Int64.self, initial: 0)
        XCTAssertNoThrow(try int64Target.applyChanges([change], source: .remote))
        XCTAssertEqual(self.plainValue(int64Target, Int64.self), 0)
    }

    func test_still_reports_a_local_plain_increase_that_cannot_be_applied() throws {
        // given
        let target = try self.plainTarget(Int32.self, initial: 0)
        let crdtRoot = CRDTRoot(rootObject: target.getRootObject())
        let id = self.changeID(clientSeq: 2, lamport: 2)
        let nonPrimitive = IncreaseOperation(
            parentCreatedAt: self.plainCounterCreatedAt,
            value: CRDTObject(createdAt: id.createTimeTicket(delimiter: 1)),
            executedAt: id.createTimeTicket(delimiter: 2)
        )
        let badDelta = try XCTUnwrap(self.plainIncrease(.string("1")).operations.first)

        for source in [OpSource.local, OpSource.undoRedo] {
            // when / then - a delta the counter refuses keeps the code the counter threw
            XCTAssertThrowsError(try badDelta.execute(root: crdtRoot, versionVector: nil, source: source)) { error in
                XCTAssertEqual((error as? YorkieError)?.code, .errUnimplemented, "\(error)")
                XCTAssertTrue((error as? YorkieError)?.message.contains("Unsupported type of value") == true, "\(error)")
            }

            // when / then - a value that is not a primitive is an invalid argument, as in JS
            XCTAssertThrowsError(try nonPrimitive.execute(root: crdtRoot, versionVector: nil, source: source)) { error in
                XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument, "\(error)")
                XCTAssertTrue((error as? YorkieError)?.message.contains("only Primitive can be increased") == true, "\(error)")
            }
        }
        XCTAssertEqual(self.plainValue(target, Int32.self), 0)
    }

    func test_keeps_failing_a_remote_increase_on_an_element_that_is_not_a_counter() throws {
        // given - the target is the root object, and another one does not exist at all
        let target = try self.plainTarget(Int32.self, initial: 0)
        let id = self.changeID(clientSeq: 2, lamport: 2)
        let value = Primitive(value: .integer(1), createdAt: id.createTimeTicket(delimiter: 1))

        for parent in [TimeTicket.initial, TimeTicket(lamport: 99, delimiter: 1, actorID: self.actorID)] {
            let op = IncreaseOperation(parentCreatedAt: parent, value: value, executedAt: id.createTimeTicket(delimiter: 2))

            // when / then - not skipped for any source
            for source in [OpSource.remote, .local, .undoRedo] {
                XCTAssertThrowsError(try target.applyChanges([Change(id: id, operations: [op])], source: source), "\(parent) \(source)")
            }
        }
        XCTAssertEqual(self.plainValue(target, Int32.self), 0)
    }

    // MARK: - Double delta on a plain counter (Go counter.go Increase / JS counter.ts increase)

    func test_applies_a_double_delta_to_a_plain_counter_truncated_toward_zero() throws {
        let cases: [(Double, Int32)] = [(1.5, 1), (-1.5, -1), (2.9, 2), (-0.9, 0), (0.0, 0)]
        for (delta, expected) in cases {
            let target = try self.plainTarget(Int32.self, initial: 0)
            try target.applyChanges([self.plainIncrease(.double(delta))], source: .remote)
            XCTAssertEqual(self.plainValue(target, Int32.self), expected, "Int32 counter + \(delta)")

            let long = try self.plainTarget(Int64.self, initial: 0)
            try long.applyChanges([self.plainIncrease(.double(delta))], source: .remote)
            XCTAssertEqual(self.plainValue(long, Int64.self), Int64(expected), "Int64 counter + \(delta)")
        }
    }

    func test_wraps_a_double_delta_at_the_counter_width() throws {
        // Int32 counter: sum computed in float64, then wrapped to 32 bits (Go TruncFloatToInt32).
        let int32Max = try self.plainTarget(Int32.self, initial: Int32.max)
        try int32Max.applyChanges([self.plainIncrease(.double(1))], source: .remote)
        XCTAssertEqual(self.plainValue(int32Max, Int32.self), Int32.min)

        // 10 + 2^60 rounds the 10 away in float64 -> 2^60 -> low 32 bits are 0 (Go counter.go comment).
        let tenPlus = try self.plainTarget(Int32.self, initial: 10)
        try tenPlus.applyChanges([self.plainIncrease(.double(0x1p60))], source: .remote)
        XCTAssertEqual(self.plainValue(tenPlus, Int32.self), 0)

        // Int64 counter: Double -> int64 wraps modulo 2^64 (Go TruncFloatToInt64, JS BigInt.asIntN(64)).
        let longBig = try self.plainTarget(Int64.self, initial: 0)
        try longBig.applyChanges([self.plainIncrease(.double(1e19))], source: .remote)
        XCTAssertEqual(self.plainValue(longBig, Int64.self), -8_446_744_073_709_551_616)

        // 10 + 1e19: the 10 is rounded away in float64, 1e19 mod 2^64 has the low 32 bits 0x89E80000.
        let tenPlusBig = try self.plainTarget(Int32.self, initial: 10)
        try tenPlusBig.applyChanges([self.plainIncrease(.double(1e19))], source: .remote)
        XCTAssertEqual(self.plainValue(tenPlusBig, Int32.self), -1_981_284_352)

        let longMax = try self.plainTarget(Int64.self, initial: Int64.max)
        try longMax.applyChanges([self.plainIncrease(.double(1))], source: .remote)
        XCTAssertEqual(self.plainValue(longMax, Int64.self), Int64.min)
    }

    func test_leaves_a_plain_counter_alone_for_a_non_finite_double_delta() throws {
        for delta in [Double.nan, .infinity, -.infinity] {
            let intCounter = try self.plainTarget(Int32.self, initial: 7)
            XCTAssertNoThrow(try intCounter.applyChanges([self.plainIncrease(.double(delta))], source: .remote), "\(delta)")
            XCTAssertEqual(self.plainValue(intCounter, Int32.self), 7, "\(delta)")

            let longCounter = try self.plainTarget(Int64.self, initial: 7)
            XCTAssertNoThrow(try longCounter.applyChanges([self.plainIncrease(.double(delta))], source: .remote), "\(delta)")
            XCTAssertEqual(self.plainValue(longCounter, Int64.self), 7, "\(delta)")
        }
    }

    func test_reports_the_truncated_delta_in_the_increase_op_info_of_a_double() throws {
        let target = try self.plainTarget(Int32.self, initial: 0)
        let crdtRoot = CRDTRoot(rootObject: target.getRootObject())
        let op = try XCTUnwrap(self.plainIncrease(.double(-2.7)).operations.first)

        let result = try XCTUnwrap(op.execute(root: crdtRoot, versionVector: nil, source: .remote))

        XCTAssertEqual((result.opInfos.first as? IncreaseOpInfo)?.value, -2)
    }

    func test_applies_the_same_pack_the_same_way_on_a_counter_that_skipped() throws {
        // convergence: a refused delta is dropped, so a following good increase lands on both replicas
        let first = try self.plainTarget(Int32.self, initial: 0)
        let second = try self.plainTarget(Int32.self, initial: 0)
        let pack = [self.plainIncrease(.string("x"), clientSeq: 2, lamport: 2), self.plainIncrease(.integer(5), clientSeq: 3, lamport: 3)]
        try first.applyChanges(pack, source: .remote)
        try second.applyChanges(pack, source: .remote)
        XCTAssertEqual(self.plainValue(first, Int32.self), 5)
        XCTAssertEqual(self.plainValue(second, Int32.self), 5)
    }

    func test_emits_no_increase_op_info_and_no_executed_operation_for_a_skipped_increase() throws {
        // given
        let target = try self.plainTarget(Int32.self, initial: 0)
        let crdtRoot = CRDTRoot(rootObject: target.getRootObject())
        let id = self.changeID(clientSeq: 2, lamport: 2)
        let nonPrimitive = IncreaseOperation(
            parentCreatedAt: self.plainCounterCreatedAt,
            value: CRDTObject(createdAt: id.createTimeTicket(delimiter: 1)),
            executedAt: id.createTimeTicket(delimiter: 2)
        )
        let refused = try XCTUnwrap(self.plainIncrease(.string("1")).operations.first)
        let nonFinite = try XCTUnwrap(self.plainIncrease(.double(.nan)).operations.first)
        let change = Change(id: id, operations: [nonPrimitive, refused, nonFinite])
        var presences: [ActorID: StringValueTypeDictionary] = [:]

        // when
        let result = try change.execute(root: crdtRoot, presences: &presences, source: .remote)

        // then
        XCTAssertTrue(result.opInfos.isEmpty)
        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertEqual(self.plainValue(target, Int32.self), 0)
    }

    func test_applies_a_wire_level_increase_that_carries_a_double() throws {
        // given - a JS peer's `counter.increase(1.5)` travels as a Double primitive
        let target = try self.plainTarget(Int32.self, initial: 0)
        let id = self.changeID(clientSeq: 2, lamport: 2)
        let op = IncreaseOperation(
            parentCreatedAt: self.plainCounterCreatedAt,
            value: Primitive(value: .double(1.5), createdAt: id.createTimeTicket(delimiter: 1)),
            executedAt: id.createTimeTicket(delimiter: 2)
        )
        let pbOps = Converter.toOperations([op])

        // when
        let decoded = try Converter.fromOperations(pbOps)
        let increase = try XCTUnwrap(decoded.first as? IncreaseOperation)
        try target.applyChanges([Change(id: id, operations: [increase])], source: .remote)

        // then
        XCTAssertEqual((increase.value as? Primitive)?.value, .double(1.5))
        XCTAssertEqual(self.plainValue(target, Int32.self), 1)
    }
}
