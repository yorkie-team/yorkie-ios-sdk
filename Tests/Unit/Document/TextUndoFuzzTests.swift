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

/// Ports `packages/sdk/test/unit/document/text_undo_fuzz_test.ts` from yorkie-js-sdk v0.7.26
/// (yorkie-js-sdk#1514), itself a port of Go's `text_undo_fuzz_test.go` (yorkie-team/yorkie#2310).
/// It drives Text undo and redo against concurrent deletions over the push/pull model of
/// `AdvSync.swift`, every change through protobuf. The default run takes a few seeds per required
/// setting; more seeds, and the setting that is only reported, run with
///
///     TEXT_UNDO_FUZZ_SEEDS=1000 TEXT_UNDO_FUZZ_FULL=1 swift test --filter TextUndoFuzzTests
///
/// It requires convergence with GC off, and with GC on when nothing is inserted, and that every
/// replica's removal ledger survives a snapshot. With GC on and inserts, a recreated piece can
/// still land after text inserted between the gap and the following piece of its insertion, so
/// that setting is only reported. The PRNG is the same mulberry32 as the JS test's, so a seed
/// replays the same history as on the JS side.
final class TextUndoFuzzTests: XCTestCase {
    private let seeds = Int(ProcessInfo.processInfo.environment["TEXT_UNDO_FUZZ_SEEDS"] ?? "") ?? 10
    private let full = ProcessInfo.processInfo.environment["TEXT_UNDO_FUZZ_FULL"] != nil

    /// Passes the server log through protobuf.
    @MainActor
    private func wire(_ server: AdvServer) throws {
        server.log = try server.log.map { change in
            let pack = try Converter.fromChangePack(Converter.toChangePack(pack: ChangePack(
                key: "k",
                checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                isRemoved: false,
                changes: [change],
                versionVector: nil
            )))
            return pack.getChanges()[0]
        }
    }

    /// The removal ledger of every node as a value: removedAt, the removals and the cancel pairs.
    @MainActor
    private func ledger(_ text: CRDTText) -> String {
        var out = [String]()
        for node in text.rgaTreeSplit {
            let ledger = node.ledger
            var dels = [String]()
            var cancels = [String]()
            if ledger.ledgered {
                dels = ledger.dels.map { $0.toTestString }
                cancels = ledger.cancels.map { "\($0.deletion.toTestString)>\($0.cancelledAt.toTestString)" }
            } else if let removedAt = node.removedAt {
                dels = [removedAt.toTestString]
            }
            dels.sort()
            cancels.sort()
            let removedAt = node.removedAt?.toTestString ?? "-"
            out.append("\(node.id.toTestString) r=\(removedAt) d=\(dels) c=\(cancels)")
        }
        return out.joined(separator: "|")
    }

    @MainActor
    private func textOf(_ doc: Document) -> CRDTText? {
        doc.getRootObject().get(key: "t") as? CRDTText
    }

    /// Reports a ledger that does not survive a snapshot.
    @MainActor
    private func snapshotMismatch(_ doc: Document) -> String {
        guard let want = self.textOf(doc) else {
            return "no text"
        }
        let got: CRDTText
        do {
            let bytes = try Converter.snapshotToBytes(root: doc.getRootObject(), presences: [:])
            guard let decoded = try Converter.bytesToSnapshot(bytes: bytes).root.get(key: "t") as? CRDTText else {
                return "decode: no text"
            }
            got = decoded
        } catch {
            return "decode: \(error)"
        }
        let wantLedger = self.ledger(want)
        let haveLedger = self.ledger(got)
        return wantLedger == haveLedger ? "" : "ledger\n \(wantLedger)\n \(haveLedger)"
    }

    @MainActor
    private func textString(_ doc: Document) -> String {
        (doc.getRoot().t as? JSONText)?.toString ?? "<missing>"
    }

    /// Runs one seed and returns "" on convergence, or the failure.
    @MainActor
    private func runSeed(_ seed: UInt32, gc: Bool, insertPct: Int, clients: Int, steps: Int) -> String {
        var rnd = AdvMulberry32(seed: seed)
        let server = AdvServer()
        let cs = newAdvClients(clients)
        do {
            try cs[0].doc.update { root, _ in
                root.t = JSONText()
                (root.t as? JSONText)?.edit(0, 0, "abcdefghij")
            }
            for client in cs {
                try server.sync(client, gc: gc)
            }
            try server.sync(cs[0], gc: gc)
        } catch {
            return "setup: \(error)"
        }
        cs[0].doc.clearHistory()

        for step in 0 ..< steps {
            let client = cs[rnd.pick(cs.count)]
            var kind = rnd.pick(10)
            if kind < 2, rnd.pick(100) >= insertPct {
                kind = 2
            }
            do {
                if kind < 2 {
                    let pos = rnd.pick(((client.doc.getRoot().t as? JSONText)?.length ?? 0) + 1)
                    let ch = String(UnicodeScalar(UInt8(65 + rnd.pick(26))))
                    try client.doc.update { root, _ in (root.t as? JSONText)?.edit(pos, pos, ch) }
                } else if kind < 5 {
                    let length = (client.doc.getRoot().t as? JSONText)?.length ?? 0
                    if length == 0 {
                        continue
                    }
                    let from = rnd.pick(length)
                    let to = from + 1 + rnd.pick(min(3, length - from))
                    try client.doc.update { root, _ in (root.t as? JSONText)?.edit(from, to, "") }
                } else if kind < 7 {
                    try client.doc.undo()
                } else if kind < 8 {
                    try client.doc.redo()
                } else {
                    try server.sync(client, gc: gc)
                    try self.wire(server)
                }
            } catch {
                return "step \(step): \(error)"
            }
            for client in cs {
                let why = self.snapshotMismatch(client.doc)
                if !why.isEmpty {
                    return "step \(step): \(why)"
                }
            }
        }
        do {
            for _ in 0 ..< 3 {
                for client in cs {
                    try server.sync(client, gc: gc)
                }
            }
        } catch {
            return "final sync: \(error)"
        }
        let want = self.textString(cs[0].doc)
        for client in cs.dropFirst() {
            let got = self.textString(client.doc)
            if got != want {
                return "diverged \"\(want)\" vs \"\(got)\""
            }
        }
        return ""
    }

    @MainActor
    private func fuzz(gc: Bool, insertPct: Int, clients: Int, required: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let name = "gc=\(gc) insert=\(insertPct)% clients=\(clients)"
        var failures = [String]()
        for seed in 0 ..< self.seeds {
            let why = self.runSeed(UInt32(seed), gc: gc, insertPct: insertPct, clients: clients, steps: 40)
            if !why.isEmpty {
                failures.append("seed \(seed): \(why)")
            }
        }
        if self.full || !failures.isEmpty {
            print("\(name): \(failures.count) of \(self.seeds) seeds failed")
        }
        if self.full {
            for failure in failures {
                print("  \(failure.split(separator: "\n").first ?? "")")
            }
        }
        if required {
            XCTAssertEqual(Array(failures.prefix(3)), [], name, file: file, line: line)
        }
    }

    @MainActor
    func test_gc_false_insert_0_clients_3() {
        self.fuzz(gc: false, insertPct: 0, clients: 3, required: true)
    }

    @MainActor
    func test_gc_false_insert_100_clients_3() {
        self.fuzz(gc: false, insertPct: 100, clients: 3, required: true)
    }

    @MainActor
    func test_gc_false_insert_100_clients_4() {
        self.fuzz(gc: false, insertPct: 100, clients: 4, required: true)
    }

    @MainActor
    func test_gc_true_insert_0_clients_3() {
        self.fuzz(gc: true, insertPct: 0, clients: 3, required: true)
    }

    /// Only reported, and only on a full sweep (`TEXT_UNDO_FUZZ_FULL=1`), as in JS.
    @MainActor
    func test_gc_true_insert_100_clients_3() throws {
        try XCTSkipUnless(self.full, "reported-only setting; set TEXT_UNDO_FUZZ_FULL=1")
        self.fuzz(gc: true, insertPct: 100, clients: 3, required: false)
    }
}
