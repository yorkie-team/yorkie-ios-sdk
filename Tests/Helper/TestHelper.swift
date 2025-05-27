/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

let defaultSnapshotThreshold = 1000

func maxVersionVector(actors: [String?]) -> VersionVector {
    var actors = actors.compactMap { $0 }

    if actors.isEmpty {
        actors = [ActorIDs.initial]
    }

    var vector: [String: Int64] = [:]
    for actor in actors {
        vector[actor] = TimeTicket.Values.maxLamport
    }

    return VersionVector(vector: vector)
}

struct ActorData {
    let actor: String
    let lamport: Int64
}

func versionVectorHelper(_ versionVector: VersionVector,
                         actorDatas: [ActorData]) async -> Bool
{
    guard versionVector.size() == actorDatas.count else {
        return false
    }

    for actorData in actorDatas {
        guard let vvLamport = versionVector.get(actorData.actor) else {
            return false
        }

        guard vvLamport == actorData.lamport else {
            return false
        }
    }

    return true
}

extension Task where Success == Never, Failure == Never {
    /**
     * `sleep` is a helper function that suspends the current task for the given milliseconds.
     */
    static func sleep(milliseconds: UInt64) async throws {
        try await self.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

func assertTrue(versionVector: VersionVector, actorDatas: [ActorData]) async {
    let result = await versionVectorHelper(versionVector, actorDatas: actorDatas)
    XCTAssertTrue(result)
}

func assertPeerElementsEqual(peers1: [PeerElement], peers2: [PeerElement]) {
    let clientIDs1 = peers1.map { $0.clientID }.sorted()
    let clientIDs2 = peers2.map { $0.clientID }.sorted()

    guard clientIDs1 == clientIDs2 else {
        XCTFail("ClientID mismatch: \(clientIDs1) != \(clientIDs2)")
        return
    }

    for clientID in clientIDs1 {
        let presence1 = peers1.first(where: { $0.clientID == clientID })?.presence ?? [:]
        let presence2 = peers2.first(where: { $0.clientID == clientID })?.presence ?? [:]

        guard presence1.count == presence2.count else {
            XCTFail("Presence count mismatch for clientID: \(clientID)")
            return
        }

        for (key, value) in presence1 {
            guard let value1 = value as? String else {
                XCTFail("Value for key '\(key)' in peer1 is not a String for clientID: \(clientID)")
                return
            }
            guard let value2 = presence2[key] as? String else {
                XCTFail("Value for key '\(key)' in peer2 is not a String for clientID: \(clientID)")
                return
            }

            guard value1 == value2 else {
                XCTFail("Mismatch for key '\(key)' in clientID: \(clientID) — '\(value1)' != '\(value2)'")
                return
            }
        }
    }
}

extension Date {
    func timeInterval(after seconds: Double) -> TimeInterval {
        return (self + seconds).timeIntervalSince1970
    }
}
