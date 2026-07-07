/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

class ChangeIDTests: XCTestCase {
    func test_with_actor() {
        let actorID = "abcdefghijklmnopqrstuvwxyz"
        let versionVector = VersionVector(vector: [actorID: 2])

        let target = ChangeID(clientSeq: 1, lamport: 2, actor: actorID, versionVector: versionVector)

        XCTAssertEqual(target.toTestString, "2:yz:1")
    }

    func test_change_lmport_to_bigger_than_current_lamport() {
        let actor = "actorID"

        let currentVector = VersionVector(vector: [actor: 2])
        let otherVector = VersionVector(vector: [actor: 10])

        let current = ChangeID(clientSeq: 1, lamport: 2, actor: actor, versionVector: currentVector)
        let other = ChangeID(clientSeq: 2, lamport: 10, actor: actor, versionVector: otherVector)

        let synced = current.syncClocks(with: other)

        XCTAssertEqual(synced.getVersionVector().get(actor), 11)
    }

    func test_change_lmport_to_smaller_than_current_lamport() {
        let actor = "actorID"

        let currentVector = VersionVector(vector: [actor: 10])
        let otherVector = VersionVector(vector: [actor: 5])

        let current = ChangeID(clientSeq: 1, lamport: 10, actor: actor, versionVector: currentVector)
        let other = ChangeID(clientSeq: 2, lamport: 5, actor: actor, versionVector: otherVector)

        let synced = current.syncClocks(with: other)

        XCTAssertEqual(synced.getVersionVector().get(actor), 11)
    }

    func test_can_create_time_ticket() {
        let actorID = "actor-1"

        let versionVector = VersionVector(vector: [actorID: 10])
        let target = ChangeID(clientSeq: 1, lamport: 2, actor: actorID, versionVector: versionVector)
        let result = target.createTimeTicket(delimiter: 3)

        XCTAssertEqual(result.toTestString, "2:actor-1:3")
    }

    // syncLamport (v0.7.11): advances the lamport clock like syncClocks, but does NOT
    // merge the other ID's version vector entries into the receiver's — only the
    // receiver's own actor entry is set. This keeps VV size O(1) for attachments that
    // opt out of GC participation.
    func test_syncLamport_advances_lamport_without_merging_the_other_actors_vv_entry() {
        let actor = "actor-1"
        let otherActor = "actor-2"

        let currentVector = VersionVector(vector: [actor: 2])
        let otherVector = VersionVector(vector: [otherActor: 10])

        let current = ChangeID(clientSeq: 1, lamport: 2, actor: actor, versionVector: currentVector)
        let other = ChangeID(clientSeq: 2, lamport: 10, actor: otherActor, versionVector: otherVector)

        let synced = current.syncLamport(with: other)

        // Lamport advances to other.lamport + 1, same as syncClocks would.
        XCTAssertEqual(synced.getLamport(), other.getLamport() + 1)

        // But the version vector keeps only the receiver's own actor entry —
        // the other actor's entry is NOT merged in.
        XCTAssertEqual(synced.getVersionVector().size(), 1)
        XCTAssertEqual(synced.getVersionVector().get(actor), other.getLamport() + 1)
        XCTAssertNil(synced.getVersionVector().get(otherActor))
    }

    // Contrast with syncClocks: given the same inputs, syncClocks DOES merge the other
    // actor's version-vector entry, growing the vector to size 2.
    func test_syncClocks_merges_the_other_actors_vv_entry_unlike_syncLamport() {
        let actor = "actor-1"
        let otherActor = "actor-2"

        let currentVector = VersionVector(vector: [actor: 2])
        let otherVector = VersionVector(vector: [otherActor: 10])

        let current = ChangeID(clientSeq: 1, lamport: 2, actor: actor, versionVector: currentVector)
        let other = ChangeID(clientSeq: 2, lamport: 10, actor: otherActor, versionVector: otherVector)

        let synced = current.syncClocks(with: other)

        XCTAssertEqual(synced.getVersionVector().size(), 2)
        XCTAssertEqual(synced.getVersionVector().get(otherActor), 10)
    }

    func test_syncLamport_returns_self_unchanged_when_other_has_no_clocks() {
        let actor = "actor-1"
        let currentVector = VersionVector(vector: [actor: 2])
        let current = ChangeID(clientSeq: 1, lamport: 2, actor: actor, versionVector: currentVector)

        // ChangeID.initial has lamport == initialLamport and an empty version vector,
        // so hasClocks() is false.
        let other = ChangeID.initial

        let synced = current.syncLamport(with: other)

        XCTAssertEqual(synced.toTestString, current.toTestString)
        XCTAssertEqual(synced.getVersionVector().size(), current.getVersionVector().size())
        XCTAssertEqual(synced.getVersionVector().get(actor), current.getVersionVector().get(actor))
    }
}
