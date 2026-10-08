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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// A small seeded PRNG so a failing seed reproduces, mirroring the `mulberry32` generator
/// yorkie-js-sdk's port of this test uses. The exact sequence does not need to match JS's --
/// only Swift-side determinism does.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    /// Returns a value in `0..<bound`.
    mutating func next(_ bound: Int) -> Int {
        self.state ^= self.state << 13
        self.state ^= self.state >> 7
        self.state ^= self.state << 17
        return Int(self.state % UInt64(bound))
    }
}

/// Ports `packages/sdk/test/unit/document/text_normalize_pos_test.ts` from
/// yorkie-js-sdk#1442 ("Read Text.normalizePos from the index tree instead of the chain"),
/// which rewrote ``RGATreeSplit/normalizePos(_:)`` to read the already-maintained
/// `treeByIndex` sum instead of walking the `prev` chain node by node.
///
/// `assertNormalizePosMatchesChainWalk` checks `normalizePos` against its definition at every
/// offset of every node: anchored on the head, offset by the live length of every node before
/// the position's node plus the offset inside it. Tombstones are included, since remote edits
/// and reverse operations anchor on them. Each offset inside a node is also queried by an id
/// that only a floor lookup resolves, as a replica that has not split the node yet would send.
final class TextNormalizePosTests: XCTestCase {
    @discardableResult
    private func assertNormalizePosMatchesChainWalk(
        _ text: CRDTText,
        seed: Int,
        step: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let split = text.rgaTreeSplit
        let head = split.head.id
        var checks = 0
        var prefix: Int32 = 0

        // A position anchored on the head itself: the only node the chain walk never steps
        // over, and the id every other position normalizes to.
        if let atHead = try? text.normalizePos(RGATreeSplitPos(head, 0)) {
            if atHead.id != head || atHead.relativeOffset != 0 {
                XCTFail(
                    "seed \(seed) step \(step): head \(head.toTestString) normalized to " +
                        "\(atHead.toTestString), want offset 0",
                    file: file, line: line
                )
            }
            checks += 1
        } else {
            XCTFail("seed \(seed) step \(step): head failed to normalize", file: file, line: line)
        }

        var node = split.head.next
        while let current = node {
            for offset in 0 ... current.contentLength {
                let pos = RGATreeSplitPos(current.id, Int32(offset))
                guard let normalized = try? text.normalizePos(pos) else {
                    XCTFail("seed \(seed) step \(step): \(pos.toTestString) failed to normalize", file: file, line: line)
                    continue
                }
                if normalized.id != head || normalized.relativeOffset != prefix + Int32(offset) {
                    XCTFail(
                        "seed \(seed) step \(step): \(pos.toTestString) normalized to " +
                            "\(normalized.toTestString), want offset \(prefix + Int32(offset))",
                        file: file, line: line
                    )
                }
                checks += 1

                if offset == 0 || offset == current.contentLength {
                    continue
                }
                let floorID = RGATreeSplitNodeID(current.id.createdAt, current.id.offset + Int32(offset))
                let floorPos = RGATreeSplitPos(floorID, 0)
                guard let floorNormalized = try? text.normalizePos(floorPos) else {
                    XCTFail("seed \(seed) step \(step): floor \(floorPos.toTestString) failed to normalize", file: file, line: line)
                    continue
                }
                if floorNormalized.id != head || floorNormalized.relativeOffset != prefix {
                    XCTFail(
                        "seed \(seed) step \(step): floor \(floorPos.toTestString) normalized to " +
                            "\(floorNormalized.toTestString), want offset \(prefix)",
                        file: file, line: line
                    )
                }
                checks += 1
            }
            prefix += Int32(current.length)
            node = current.next
        }

        return checks
    }

    /// `chainWalk` is the definition `normalizePos` replaced, kept literally: find the floor
    /// node of the position's id (only among pieces of the same insertion), then sum the live
    /// length of every node on its `prev` chain. It answers `nil` where the old code threw: no
    /// piece of the insertion survives.
    private func chainWalk(_ text: CRDTText, _ pos: RGATreeSplitPos) -> Int32? {
        guard let entry = text.getTreeByID().floorEntry(pos.id) else {
            return nil
        }
        if entry.key != pos.id, !entry.key.hasSameCreatedAt(pos.id) {
            return nil
        }
        var total = pos.relativeOffset
        var prev = entry.value.prev
        while let prevNode = prev {
            total += Int32(prevNode.length)
            prev = prevNode.prev
        }
        return total
    }

    // given/when/then is folded into the fuzz loop itself: each step mutates the document one
    // random way, then checks `normalizePos` against the chain-walk definition before moving on.
    @MainActor
    func test_matches_the_chain_walk_across_edit_style_undo_redo_and_gc() throws {
        var checks = 0, undoCount = 0, redoCount = 0, purgedCount = 0
        let alphabet = ["a", "b", "가", "나"]

        for seed in 1 ... 30 {
            var rnd = SeededRandom(seed: UInt64(seed))
            let doc = Document(key: "normalize-pos-\(seed)")
            let actor = "0000000000000000000000\(String(format: "%02d", seed % 90 + 1))"
            doc.setActor(actor)
            try doc.update { root, _ in
                root.t = JSONText()
            }
            // Undo must reach the edits, never the text itself.
            doc.clearHistory()

            for step in 0 ..< 150 {
                let op = rnd.next(10)
                let text = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
                let currentLength = text.length

                if op < 4 {
                    let at = rnd.next(currentLength + 1)
                    let content = alphabet[0 ..< (1 + rnd.next(alphabet.count))].joined()
                    try doc.update { root, _ in
                        (root.t as? JSONText)?.edit(at, at, content)
                    }
                } else if op < 6 {
                    if currentLength > 0 {
                        let from = rnd.next(currentLength)
                        let to = min(currentLength, from + 1 + rnd.next(3))
                        try doc.update { root, _ in
                            (root.t as? JSONText)?.edit(from, to, "")
                        }
                    }
                } else if op < 7 {
                    if currentLength > 0 {
                        let from = rnd.next(currentLength)
                        let to = min(currentLength, from + 1 + rnd.next(3))
                        try doc.update { root, _ in
                            (root.t as? JSONText)?.setStyle(from, to, ["b": "1"])
                        }
                    }
                } else if op < 8 {
                    if doc.canUndo {
                        try doc.undo()
                        undoCount += 1
                    }
                } else if op < 9 {
                    if doc.canRedo {
                        try doc.redo()
                        redoCount += 1
                    }
                } else {
                    purgedCount += doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actor]))
                }

                let textAfter = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
                checks += self.assertNormalizePosMatchesChainWalk(textAfter, seed: seed, step: step)
            }
        }

        // Guard the harness itself: a sequence that never undoes, redoes or purges would pass
        // without exercising the paths that matter.
        XCTAssertGreaterThan(undoCount, 100)
        XCTAssertGreaterThan(redoCount, 10)
        XCTAssertGreaterThan(purgedCount, 100)
        XCTAssertGreaterThan(checks, 100_000)
    }

    // Ports "should resolve positions whose pieces GC purged as the chain walk did". Positions
    // taken before GC still arrive after it: a remote Edit and the undo stack both carry them.
    // Purging takes their pieces out of both trees, so the floor lookup lands on an earlier
    // surviving piece of the same insertion, or on none. Each case must resolve exactly as the
    // chain walk did -- the same offset, or the same refusal.
    @MainActor
    func test_resolves_positions_whose_pieces_gc_purged_as_the_chain_walk_did() throws {
        var staleCount = 0, refusedCount = 0, flooredCount = 0, boundaryCount = 0

        for seed in 1 ... 20 {
            var rnd = SeededRandom(seed: UInt64(seed))
            let doc = Document(key: "normalize-pos-purged-\(seed)")
            let actor = "0000000000000000000000\(String(format: "%02d", seed % 90 + 1))"
            doc.setActor(actor)
            try doc.update { root, _ in
                root.t = JSONText()
                (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
                (root.t as? JSONText)?.edit(5, 5, "0123456789")
            }

            for step in 0 ..< 40 {
                let text = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
                let split = text.rgaTreeSplit
                var stale = [RGATreeSplitPos]()
                var node = split.head.next
                while let current = node {
                    // Past the content too: a floor piece shorter than the purged one it
                    // stands in for sees `rel` run beyond its own end.
                    for offset in 0 ... (current.contentLength + 1) {
                        stale.append(RGATreeSplitPos(current.id, Int32(offset)))
                    }
                    node = current.next
                }

                let currentLength = text.length
                if rnd.next(3) == 0 || currentLength < 4 {
                    let at = rnd.next(currentLength + 1)
                    let content = String(["x", "y", "z"][0 ..< (1 + rnd.next(3))].joined())
                    try doc.update { root, _ in
                        (root.t as? JSONText)?.edit(at, at, content)
                    }
                } else {
                    let from = rnd.next(currentLength)
                    let to = min(currentLength, from + 1 + rnd.next(4))
                    try doc.update { root, _ in
                        (root.t as? JSONText)?.edit(from, to, "")
                    }
                }
                doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actor]))

                let textAfterGC = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTText)
                let head = textAfterGC.rgaTreeSplit.head.id
                for pos in stale {
                    staleCount += 1
                    guard let want = self.chainWalk(textAfterGC, pos) else {
                        XCTAssertThrowsError(try textAfterGC.normalizePos(pos), "seed \(seed) step \(step): \(pos.toTestString)")
                        refusedCount += 1
                        continue
                    }
                    guard let floorEntry = textAfterGC.getTreeByID().floorEntry(pos.id) else {
                        XCTFail("seed \(seed) step \(step): expected a floor entry for \(pos.toTestString)")
                        continue
                    }
                    if floorEntry.key != pos.id {
                        flooredCount += 1
                    }
                    if pos.relativeOffset >= floorEntry.value.contentLength {
                        boundaryCount += 1
                    }
                    let got = try textAfterGC.normalizePos(pos)
                    if got.id != head || got.relativeOffset != want {
                        XCTFail(
                            "seed \(seed) step \(step): \(pos.toTestString) normalized to " +
                                "\(got.toTestString), want offset \(want)"
                        )
                    }
                }
            }
        }

        // Guard the harness: every branch above has to have been reached.
        XCTAssertGreaterThan(refusedCount, 50)
        XCTAssertGreaterThan(flooredCount, 50)
        XCTAssertGreaterThan(boundaryCount, 50)
        XCTAssertGreaterThan(staleCount, 0)
    }

    /// Folds JS's "should cost the same to normalize at any document length" and "should keep
    /// typing linear in the length of the text" into one timing-based check. JS counts the
    /// `prev` hops a lookup takes by monkey-patching `RGATreeSplitNode.prototype.getPrev`,
    /// deterministically and without a clock. Swift classes have no prototype to patch, and
    /// adding a hop counter to ``RGATreeSplitNode`` purely so a test could read it would be
    /// production code shaped by a test, so this measures wall-clock time instead, accepting
    /// the CI-flakiness risk JS's own comment says the hop count exists to avoid.
    ///
    /// Every edit normalizes its `fromPos` to build the reverse operation
    /// (``EditOperation/execute(root:versionVector:)``), so a lookup that sums the `prev`
    /// chain made typing a document quadratic in its length: typing 8,000 characters measured
    /// ~11x the cost of typing 2,000 (four times the text) on the pre-fix chain walk in this
    /// run, against the ~4.5x a lookup that costs the same at any length should show. The
    /// threshold sits between the two, with margin on both sides so ordinary CI noise cannot
    /// flip the verdict.
    @MainActor
    func test_keeps_typing_cost_from_growing_quadratically_with_document_length() throws {
        // A wall-clock ratio is not stable on shared CI runners, so this runs only
        // when asked for; the two fuzz tests above pin correctness on every run.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YORKIE_PERF_TESTS"] == "1",
                          "set YORKIE_PERF_TESTS=1 to run the normalizePos timing check")
        func typingElapsed(_ size: Int) throws -> TimeInterval {
            let doc = Document(key: "normalize-pos-cost-\(size)")
            try doc.update { root, _ in
                root.t = JSONText()
            }
            let start = Date()
            for charIndex in 0 ..< size {
                try doc.update { root, _ in
                    (root.t as? JSONText)?.edit(charIndex, charIndex, "a")
                }
            }
            return Date().timeIntervalSince(start)
        }

        let small = try typingElapsed(2000)
        let large = try typingElapsed(8000)

        XCTAssertLessThan(
            large / small, 7.5,
            "typing 4x the text took \(large / small)x as long (small=\(small)s, large=\(large)s); " +
                "normalizePos may be back to walking the chain instead of reading the index"
        )
    }
}
