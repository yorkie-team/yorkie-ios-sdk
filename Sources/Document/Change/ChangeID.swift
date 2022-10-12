/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

import Foundation

/**
 * `ChangeID` is for identifying the Change. This is immutable.
 */
struct ChangeID {
    /**
     * `initial` represents the initial state ID. Usually this is used to
     * represent a state where nothing has been edited.
     */
    static let initial = ChangeID(clientSeq: 0, lamport: 0, actor: ActorIDs.initial)

    // `serverSeq` is optional and only present for changes stored on the server.
    private var serverSeq: Int64?

    private var clientSeq: Int
    private var lamport: Int64
    private var actor: ActorID?

    init(clientSeq: Int, lamport: Int64, actor: ActorID?) {
        self.clientSeq = clientSeq
        self.lamport = lamport
        self.actor = actor
    }

    /**
     * `next` creates a next ID of this ID.
     */
    func next() -> ChangeID {
        return ChangeID(clientSeq: self.clientSeq + 1, lamport: self.lamport + 1, actor: self.actor)
    }

    /**
     * `syncLamport` syncs lamport timestamp with the given ID.
     *
     * {@link https://en.wikipedia.org/wiki/Lamport_timestamps#Algorithm}
     */
    func syncLamport(otherLamport: Int64) -> ChangeID {
        let lamport = otherLamport > self.lamport ? otherLamport : self.lamport + 1
        return ChangeID(clientSeq: self.clientSeq, lamport: lamport, actor: self.actor)
    }

    /**
     * `createTimeTicket` creates a ticket of the given delimiter.
     */
    func createTimeTicket(delimiter: UInt32) -> TimeTicket {
        return TimeTicket(lamport: self.lamport, delimiter: delimiter, actorID: self.actor)
    }

    /**
     * `setActor` sets the given actor.
     */
    mutating func setActor(actorID: ActorID) {
        self.actor = actorID
    }

    /**
     * `getClientSeq` returns the client sequence of this ID.
     */
    func getClientSeq() -> Int {
        return self.clientSeq
    }

    /**
     * `getLamport` returns the lamport clock of this ID.
     */
    func getLamport() -> Int64 {
        return self.lamport
    }

    /**
     * `getLamportAsString` returns the lamport clock of this ID as a string.
     */
    func getLamportAsString() -> String {
        return "\(self.lamport)"
    }

    /**
     * `getActorID` returns the actor of this ID.
     */
    func getActorID() -> String? {
        return self.actor
    }

    /**
     * `getStructureAsString` returns a string containing the meta data of this ID.
     */
    func getStructureAsString() -> String {
        var actor: String
        if let value = self.actor {
            actor = String(value.substring(from: 22, to: 24))
        } else {
            actor = "nil"
        }
        return "\(self.lamport):\(actor):\(self.clientSeq)"
    }
}
