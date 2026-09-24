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

/// `ElementRHT.set` resolves LWW on `getPositionedAt()`, which is the member's `movedAt`.
/// `SetOperation.execute` anchors on the operation's `executedAt`, so every remote replica
/// and the server stamp the member from that ticket -- the originating replica has to stamp
/// it from the same one.
///
/// The trap is that `setPrimitive` mints a SECOND ticket for the `Primitive`'s own
/// `createdAt`, so deriving the anchor locally from `value.createdAt` gives the originator a
/// different `movedAt` than everyone else. It only shows under concurrency, which is why it
/// is pinned directly here.
final class SetOperationAnchorTests: XCTestCase {
    @MainActor
    func test_a_primitive_member_is_positioned_at_the_same_ticket_on_every_replica() throws {
        // given -- one document sets a primitive member.
        let origin = Document(key: "anchor-origin")
        origin.setActor("000000000000000000000001")
        try origin.update { root, _ in root.k = Int64(1) }

        // when -- the change is shipped and applied the way a peer would.
        let pack = origin.createChangePack()
        let shipped = try Converter.fromChanges(Converter.toChanges(pack.getChanges()))

        let peer = Document(key: "anchor-origin")
        peer.setActor("000000000000000000000002")
        try peer.applyChanges(shipped, source: .remote)

        // then
        let originMember = try XCTUnwrap(origin.getRootObject().get(key: "k"))
        let peerMember = try XCTUnwrap(peer.getRootObject().get(key: "k"))
        XCTAssertEqual(originMember.getPositionedAt(), peerMember.getPositionedAt(),
                       "the originating replica anchored the member on a different ticket than the peer, "
                           + "so the two resolve a later concurrent set differently")
    }
}
