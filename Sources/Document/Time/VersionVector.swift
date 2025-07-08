/*
 * Copyright 2024 The Yorkie Authors. All rights reserved.
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

/**
 * `VersionVector` is a vector clock that is used to detect the relationship
 * between changes whether they are causally related or concurrent. It is
 * similar to vector clocks, but it is synced with lamport timestamp of the
 * change.
 */
public struct VersionVector: Sendable {
    /**
     * `initial` is the initial version vector.
     */
    static let initial = VersionVector(vector: [:])

    private var vector: [String: Int64]

    public init(vector: [String: Int64]? = nil) {
        self.vector = vector ?? [:]
    }

    /**
     * `set` sets the lamport timestamp of the given actor.
     */
    public mutating func set(actorID: ActorID, lamport: Int64) {
        self.vector[actorID] = lamport
    }
    
    /**
       * `unset` removes the version for the given actor from the VersionVector.
       */
      public mutating func unset(actorID: String) {
          self.vector.removeValue(forKey: actorID)
      }

    /**
     * `get` gets the lamport timestamp of the given actor.
     */
    public func get(_ actorID: ActorID) -> Int64? {
        return self.vector[actorID]
    }

    /**
     * `maxLamport` returns max lamport value from vector
     */
    public func maxLamport() -> Int64 {
        var max = Int64(0)

        for (_, lamport) in self where lamport > max {
            max = lamport
        }

        return max
    }
    
    /**
     * `max` returns new version vector which consists of max value of each vector
     */
    public func max(other: VersionVector) -> VersionVector {
        var maxVector = [String: Int64]()

        for (actorID, lamport) in other {
            let currentLamport = self.vector[actorID] ?? lamport
            let maxLamport = Swift.max(currentLamport, lamport)

            maxVector[actorID] = maxLamport
        }

        for (actorID, lamport) in self {
            let otherLamport = other.get(actorID) ?? lamport
            let maxLamport = Swift.max(otherLamport, lamport)

            maxVector[actorID] = maxLamport
        }

        return VersionVector(vector: maxVector)
    }

    /**
     * `afterOrEqual` returns vector[other.actorID] is greaterOrEqual than given ticket's lamport
     */
    public func afterOrEqual(other: TimeTicket) -> Bool {
        guard let lamport = self.vector[other.actorID] else {
            return false
        }

        return lamport >= other.lamport
    }

    /**
     * `deepcopy` returns a deep copy of this `VersionVector`.
     */
    public func deepcopy() -> VersionVector {
        var copied: [String: Int64] = [:]

        for (actorID, lamport) in self {
            copied[actorID] = lamport
        }

        return VersionVector(vector: copied)
    }

    /**
     * `filter` returns new version vector consist of filter's actorID.
     */
    public func filter(versionVector: VersionVector) -> VersionVector {
        var filtered: [String: Int64] = [:]

        for (actorID, _) in versionVector {
            guard let lamport = self.vector[actorID] else {
                continue
            }
            filtered[actorID] = lamport
        }

        return VersionVector(vector: filtered)
    }

    /**
     * `size` returns size of version vector
     */
    public func size() -> Int {
        return self.vector.count
    }
}

extension VersionVector: Sequence {
    public func makeIterator() -> [String: Int64].Iterator {
        return self.vector.makeIterator()
    }
}
