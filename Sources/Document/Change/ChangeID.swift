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
    private let initialLamport = TimeTicket.Values.initialLamport
    /**
     * `initial` represents the initial state ID. Usually this is used to
     * represent a state where nothing has been edited.
     */
    static let initial = ChangeID(clientSeq: 0, lamport: 0, actor: ActorIDs.initial, versionVector: .initial)

    // `serverSeq` is optional and only present for changes stored on the server.
    private var serverSeq: Int64?

    // `clientSeq` is the sequence number of the client that created this change.
    private let clientSeq: UInt32

    // `lamport` and `actor` are the lamport clock and the actor of this change.
    // This is used to determine the order of changes in logical time.
    private var lamport: Int64
    private var actor: ActorID

    private var versionVector: VersionVector

    init(clientSeq: UInt32, lamport: Int64, actor: ActorID, versionVector: VersionVector, serverSeq: Int64? = nil) {
        self.clientSeq = clientSeq
        self.lamport = lamport
        self.actor = actor
        self.versionVector = versionVector
        self.serverSeq = serverSeq
    }

    /**
     * `hasClocks` returns true if this ID has logical clocks.
     */
    func hasClocks() -> Bool {
        return self.versionVector.size() > 0 && self.lamport != self.initialLamport
    }

    /**
     * `next` creates a next ID of this ID.
     */
    func next(_ excludeClocks: Bool = false) -> ChangeID {
        if excludeClocks {
            return .init(
                clientSeq: self.clientSeq + 1,
                lamport: self.lamport,
                actor: self.actor,
                versionVector: .initial,
                serverSeq: self.initialLamport
            )
        }
        var vector = self.versionVector.deepcopy()
        vector.set(actorID: self.actor, lamport: self.lamport + 1)

        return ChangeID(clientSeq: self.clientSeq + 1,
                        lamport: self.lamport + 1,
                        actor: self.actor,
                        versionVector: vector)
    }

    /**
     * `syncClocks` syncs logical clocks with the given ID.
     */
    @discardableResult
    func syncClocks(with other: ChangeID) -> ChangeID {
        if other.hasClocks() == false {
            return self
        }
        let lamport = other.lamport > self.lamport ? other.lamport + 1 : self.lamport + 1

        let otherVV = other.versionVector
        let maxVersionVector = self.versionVector.max(other: otherVV)

        var newID = ChangeID(
            clientSeq: self.clientSeq,
            lamport: lamport,
            actor: self.actor,
            versionVector: maxVersionVector
        )
        newID.versionVector.set(actorID: self.actor, lamport: lamport)
        return newID
    }

    /**
     * `setClocks` sets the given clocks to this ID. This is used when the snapshot
     * is given from the server.
     */
    @discardableResult
    func setClocks(with otherLamport: Int64, vector: VersionVector) -> ChangeID {
        let lamport = otherLamport > self.lamport ? otherLamport + 1 : self.lamport + 1

        // clone another vector before mutating
        var vector = vector
        vector.unset(actorID: ActorIDs.initial)

        var maxVersionVector = self.versionVector.max(other: vector)
        maxVersionVector.set(actorID: self.actor, lamport: lamport)

        return ChangeID(clientSeq: self.clientSeq,
                        lamport: lamport,
                        actor: self.actor,
                        versionVector: maxVersionVector)
    }

    /**
     * `createTimeTicket` creates a ticket of the given delimiter.
     */
    func createTimeTicket(delimiter: UInt32) -> TimeTicket {
        return TimeTicket(lamport: self.lamport, delimiter: delimiter, actorID: self.actor)
    }

    /**
     * `setLamport` sets the given lamport clock.
     */
    func setLamport(_ lamport: Int64) -> ChangeID {
        return .init(
            clientSeq: self.clientSeq,
            lamport: lamport,
            actor: self.actor,
            versionVector: self.versionVector,
            serverSeq: self.serverSeq
        )
    }

    /**
     * `setActor` sets the given actor.
     */
    func setActor(_ actorID: ActorID) -> ChangeID {
        ChangeID(clientSeq: self.clientSeq,
                 lamport: self.lamport,
                 actor: actorID,
                 versionVector: self.versionVector,
                 serverSeq: self.serverSeq)
    }

    /**
     * `setVersionVector` sets the given version vector.
     */
    func setVersionVector(_ versionVector: VersionVector) -> ChangeID {
        ChangeID(clientSeq: self.clientSeq,
                 lamport: self.lamport,
                 actor: self.actor,
                 versionVector: versionVector,
                 serverSeq: self.serverSeq)
    }

    /**
     * `getClientSeq` returns the client sequence of this ID.
     */
    func getClientSeq() -> UInt32 {
        return self.clientSeq
    }

    /**
     * `getServerSeq` returns the server sequence of this ID.
     */
    func getServerSeq() -> String {
        if let serverSeq {
            return String(serverSeq)
        } else {
            return ""
        }
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
     * `getVersionVector` returns the version vector of this ID.
     */
    func getVersionVector() -> VersionVector {
        return self.versionVector
    }

    /**
     * `toTestString` returns a string containing the meta data of this ID.
     */
    var toTestString: String {
        "\(self.lamport):\(String(self.actor.suffix(2))):\(self.clientSeq)"
    }
}
