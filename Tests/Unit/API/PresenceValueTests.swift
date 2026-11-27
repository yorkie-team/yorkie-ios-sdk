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

/// Ported from `presence_value_test.ts` (yorkie-js-sdk#1559, yorkie#2386).
///
/// iOS keeps a presence value as its raw wire string and decodes it lazily with a raw-text fallback
/// (`String.toJSONObject`), so a non-JSON value never throws out of a pull. These tests pin that.
@MainActor
final class PresenceValueTests: XCTestCase {
    private let sourceActor = "000000000000000000000001"

    func test_decodes_a_non_JSON_value_to_its_raw_text() {
        // given
        var pb = PbPresence()
        pb.data = ["name": "\"a\"", "cursor": "moved"]

        // when
        let presence = Converter.fromPresence(pbPresence: pb).mapValues { $0.toJSONObject }

        // then
        XCTAssertEqual(presence["name"] as? String, "a")
        XCTAssertEqual(presence["cursor"] as? String, "moved")
    }

    func test_reads_the_value_the_server_repair_writes_the_same_way() {
        // given - a server older than yorkie#2386 hands on the raw text, a newer one its JSON encoding
        var rawPb = PbPresence()
        rawPb.data = ["cursor": "moved"]
        var repairedPb = PbPresence()
        repairedPb.data = ["cursor": "\"moved\""]

        // when
        let raw = Converter.fromPresence(pbPresence: rawPb).mapValues { $0.toJSONObject }
        let repaired = Converter.fromPresence(pbPresence: repairedPb).mapValues { $0.toJSONObject }

        // then
        XCTAssertEqual(raw["cursor"] as? String, "moved")
        XCTAssertEqual(raw["cursor"] as? String, repaired["cursor"] as? String)
    }

    func test_applies_a_pulled_pack_that_carries_one() throws {
        // given
        let source = Document(key: "d")
        source.setActor(self.sourceActor)
        try source.update { root, presence in
            root.k = "v"
            presence.set(["name": "a", "cursor": ["x": 1, "y": 1]])
        }
        var pbPack = Converter.toChangePack(pack: source.createChangePack())
        pbPack.changes[0].presenceChange.presence.data["cursor"] = "moved"
        pbPack.checkpoint.serverSeq = 1

        // when - the pack must apply and the checkpoint advance, so the change is not redelivered
        let target = Document(key: "d")
        try target.applyChangePack(Converter.fromChangePack(pbPack))

        // then
        XCTAssertEqual((target.getRootObject().get(key: "k") as? Primitive)?.value, .string("v"))
        let presence = try XCTUnwrap(target.getPresenceForTest(self.sourceActor))
        XCTAssertEqual(presence["name"] as? String, "a")
        XCTAssertEqual(presence["cursor"] as? String, "moved")
        XCTAssertEqual(target.checkpoint.getServerSeq(), 1)
    }
}
