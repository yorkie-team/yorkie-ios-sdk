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

func versionVectorHelper(versionVector: VersionVector, actorDatas: [ActorData]) -> Bool {
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
