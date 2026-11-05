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

import Foundation
@testable import Yorkie

/// Ports `packages/sdk/test/helper/adv_sync.ts` from yorkie-js-sdk v0.7.26: the push/pull model of
/// Go's `pkg/document/adv_sync_test.go`, for the randomized harnesses that drive replicas through a
/// model server.

/// A small seeded PRNG (mulberry32), so a seed replays the same history. Bit-for-bit the same
/// sequence as the JS helper.
struct AdvMulberry32 {
    private var state: UInt32

    init(seed: UInt32) {
        self.state = seed
    }

    mutating func next() -> Double {
        self.state = self.state &+ 0x6D2B_79F5
        var mixed = self.state
        mixed = (mixed ^ (mixed >> 15)) &* (mixed | 1)
        mixed ^= mixed &+ ((mixed ^ (mixed >> 7)) &* (mixed | 61))
        return Double(mixed ^ (mixed >> 14)) / 4_294_967_296
    }

    mutating func pick(_ bound: Int) -> Int {
        Int(self.next() * Double(bound))
    }
}

/// Go's `time.MinVersionVector`: element-wise min, and 0 for an actor any vector does not carry.
func advMinVersionVector(_ vectors: [VersionVector]) -> VersionVector {
    var actors = Set<String>()
    for vector in vectors {
        for (actor, _) in vector {
            actors.insert(actor)
        }
    }
    var out = VersionVector()
    for actor in actors {
        var minimum: Int64?
        for vector in vectors {
            let lamport = vector.get(actor) ?? 0
            if minimum == nil || lamport < minimum! {
                minimum = lamport
            }
        }
        out.set(actorID: actor, lamport: minimum!)
    }
    return out
}

/// A replica attached to an ``AdvServer``.
@MainActor
final class AdvClient {
    let doc: Document
    let id: String
    var cursor = 0

    init(doc: Document, id: String) {
        self.doc = doc
        self.id = id
    }
}

/// Returns `count` replicas of one document under the actors 1...count.
@MainActor
func newAdvClients(_ count: Int) -> [AdvClient] {
    (0 ..< count).map { index in
        let id = String(repeating: "0", count: 23) + String(index + 1)
        let doc = Document(key: "adv-doc")
        doc.setActor(id)
        return AdvClient(doc: doc, id: id)
    }
}

/// Models the server's pushpull: one ordered change log, one stored version vector row per client
/// (the vector its push carried), and minVV = element-wise min over the stored rows. A client only
/// ever sees minVV as the version vector of a pull response, and `applyChangePack` is what runs GC
/// with it, so GC can never run at a moment the protocol would not produce.
@MainActor
final class AdvServer {
    var log: [Change] = []
    private var rows: [String: VersionVector] = [:]

    /// One PushPull round trip: push local changes, store the request's vector, pull everything
    /// the server holds that this client has not seen, and hand the response (changes + minVV) to
    /// `applyChangePack`, which applies then collects.
    func sync(_ client: AdvClient, gc: Bool) throws {
        let pack = client.doc.createChangePack()
        let pushed = pack.getChanges()
        self.log.append(contentsOf: pushed)
        self.rows[client.id] = pack.getVersionVector()?.deepcopy() ?? VersionVector()
        let lastSeq = pushed.last?.id.getClientSeq() ?? 0

        let pulled = self.log[client.cursor...].filter { $0.id.getActorID() != client.id }
        client.cursor = self.log.count

        let vector = gc ? advMinVersionVector(Array(self.rows.values)) : VersionVector.initial
        try client.doc.applyChangePack(ChangePack(
            key: client.doc.getKey(),
            checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
            isRemoved: false,
            changes: pulled,
            versionVector: vector
        ))
    }
}
